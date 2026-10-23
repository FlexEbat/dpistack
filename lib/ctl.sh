#!/usr/bin/env bash
# The privileged verbs of dpistack (tech.md 4.5): status, start, stop, config
# editing, rules, interfaces, mode, tests, health, panel password. They are
# part of the one `dpistack` command (install.sh dispatches here); the panel
# and the watchdog reach them through `sudo -n dpistack <verb>`. Sourced by
# install.sh after the other libraries; it defines functions only.
#
# Exit codes: 0 ok, 1 error, 2 usage, 3 check failed, 4 component
# absent, 5 name outside the allowed list.

COMPONENTS=(suricata evebox ntopng redis victoriametrics prometheus panel watch rules)
LOGS_MAX=1000
LOGS_DEFAULT=100

MODE_TIMEOUT_DEFAULT=120
MODE_TIMEOUT_MIN=10
MODE_TIMEOUT_MAX=3600
MODE_ROLLBACK_UNIT="dpistack-mode-rollback"

RULES_SEARCH_MAX=50

ctl_usage() {
	cat <<'USAGE'
Использование: dpistack <команда> [аргументы]

  status [--json]                    состояние компонентов
  start|stop|restart <id>            управление компонентом
  reload suricata                    перечитать правила без остановки
  logs <id> [-n N] [--follow]        журнал компонента, N до 1000 (--until-stdin-closed: для панели)
  config-read <имя>                  печатает текущий файл
  config-write <имя> [--apply|--check] новое содержимое со stdin; --check только проверяет
  settings list [--json] | check K=V... | set [--apply|--apply-heavy] [--confirm-access] K=V... | secret KEY | job
  config-revert <имя>                возвращает последний бэкап
  reconfigure [--dry-run]            применяет текущий dpistack.conf
  rules-update                       обновить правила с откатом при ошибке
  rules-sources list [--enabled]|enable|disable|add-url|remove [арг]
  rules-group enable|disable <группа>
  rules-sid enable|disable <sid>
  rules-search <запрос>              до 50 правил по sid или msg
  iface list|add|remove [имя]        интерфейсы захвата
  mode ids|ips [--confirm-timeout S] режим Suricata; ips откатывается сам без mode-confirm (по умолчанию 120 с)
  mode status [--json]               режим, метод и обратный отсчёт
  mode-confirm                       подтвердить переключение в ips
  fw apply|remove|restore            цепочка DPISTACK (restore: при загрузке)
  panel-passwd                       пароль панели со stdin
  test bittorrent|https|all [--json] проверочные тесты (раздел 10)
  health [--json]                    один прогон watchdog
  version                            версия набора

Имена конфигов: suricata.yaml evebox.yaml ntopng.conf dpistack.conf local.rules
                enable.conf disable.conf modify.conf drop.conf

Компоненты: suricata evebox ntopng redis victoriametrics prometheus panel watch rules
USAGE
}

fail() {
	# fail <code> <message>
	local code="$1"
	shift
	echo "dpistack: $*" >&2
	exit "$code"
}

in_list() {
	# in_list <item> <list...>
	local item="$1" x
	shift
	for x in "$@"; do
		[[ "$x" == "$item" ]] && return 0
	done
	return 1
}

# Unit load state is the only portable "is it installed" test that
# also covers units for source builds, which have no package.
unit_loaded() {
	local state
	state=$(systemctl show -p LoadState --value "$1" 2>/dev/null)
	[[ -n "$state" && "$state" != "not-found" ]]
}

# component_unit <id> - prints the unit that controls the component.
component_unit() {
	# docker runtime: no unit, the compose service is addressed as docker:<id>.
	if [[ "$1" =~ ^(suricata|evebox|ntopng|redis|victoriametrics|prometheus|panel)$ && "$(component_runtime "$1")" == "docker" ]]; then
		echo "docker:$1"
		return
	fi
	case "$1" in
	suricata) echo "suricata.service" ;;
	evebox) echo "evebox.service" ;;
	ntopng) echo "ntopng.service" ;;
	redis)
		# redis.service on rpm, redis-server.service on deb.
		if unit_loaded "redis-server.service"; then
			echo "redis-server.service"
		else
			echo "redis.service"
		fi
		;;
	victoriametrics) echo "dpistack-vm.service" ;;
	prometheus) echo "prometheus.service" ;;
	panel) echo "dpistack-panel.service" ;;
	watch) echo "dpistack-watch.timer" ;;
	rules) echo "dpistack-rules.timer" ;;
	esac
}

# component_listed <id> - backend components exist only when selected.
component_listed() {
	case "$1" in
	victoriametrics | prometheus)
		[[ "$(conf_get METRICS_BACKEND none)" == "$1" ]]
		;;
	*) return 0 ;;
	esac
}

component_runtime() {
	case "$1" in
	suricata) conf_get SURICATA_RUNTIME native ;;
	evebox) conf_get EVEBOX_RUNTIME native ;;
	ntopng | redis) conf_get NTOPNG_RUNTIME native ;;
	victoriametrics | prometheus) conf_get METRICS_BACKEND_RUNTIME native ;;
	panel) conf_get PANEL_RUNTIME native ;;
	*) echo native ;;
	esac
}

component_version() {
	if [[ "$(component_unit "$1")" == docker:* ]]; then
		docker_compose_argv
		"${DOCKER_COMPOSE_ARGV[@]}" ps --format '{{.Image}}' "$1" 2>/dev/null | head -1
		return 0
	fi
	local pkg=""
	case "$1" in
	suricata) pkg="suricata" ;;
	evebox) pkg="evebox" ;;
	ntopng) pkg="ntopng" ;;
	redis)
		pkg="redis-server"
		command -v dpkg-query >/dev/null 2>&1 || pkg="redis"
		;;
	*) return 0 ;;
	esac
	local v
	if command -v dpkg-query >/dev/null 2>&1; then
		v=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)
	else
		v=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null) || v=""
	fi
	if [[ -z "$v" && "$1" == "suricata" ]] && command -v suricata >/dev/null 2>&1; then
		# Source builds have no package; the binary reports its version.
		v=$(suricata -V 2>/dev/null | sed -n 's/.*version \([0-9][^ ]*\).*/\1/p' | head -1)
	fi
	echo "$v"
}

component_state() {
	# component_state <unit> -> active|inactive|failed|absent
	local unit="$1"
	if [[ "$unit" == docker:* ]]; then
		docker_component_state "${unit#docker:}"
		return
	fi
	if ! unit_loaded "$unit"; then
		echo absent
		return
	fi
	local s
	s=$(systemctl is-active "$unit" 2>/dev/null)
	case "$s" in
	active | failed) echo "$s" ;;
	*) echo inactive ;;
	esac
}

json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\t'/\\t}"
	s="${s//$'\r'/\\r}"
	# the other control characters have no place in a JSON string
	s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
	printf '%s' "$s"
}

ctl_cmd_status() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "status: неизвестный аргумент" ;;
	esac
	[[ $# -le 1 ]] || fail 2 "status: лишние аргументы"

	local plugin=absent
	[[ -e "$(path_suricata_ndpi_plugin)" ]] && plugin=loaded

	local id unit runtime state enabled version first=1
	((json)) && printf '{"components":['
	for id in "${COMPONENTS[@]}"; do
		component_listed "$id" || continue
		unit=$(component_unit "$id")
		runtime=$(component_runtime "$id")
		state=$(component_state "$unit")
		if [[ "$state" == "absent" ]]; then
			enabled=false
		elif [[ "$unit" == docker:* ]]; then
			# restart: unless-stopped brings the container back at boot.
			enabled=true
		elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
			enabled=true
		else
			enabled=false
		fi
		version=$(component_version "$id")
		if ((json)); then
			((first)) || printf ','
			first=0
			printf '{"id":"%s","runtime":"%s","state":"%s","enabled":%s,"version":"%s"}' \
				"$id" "$runtime" "$state" "$enabled" "$(json_escape "$version")"
		else
			printf '%-16s %-7s %-9s enabled=%-5s %s\n' "$id" "$runtime" "$state" "$enabled" "$version"
		fi
	done
	if ((json)); then
		printf '],"ndpi_plugin":"%s"}\n' "$plugin"
	else
		echo "ndpi_plugin      $plugin"
	fi
}

# resolve_component <id> - validates the id (5) and presence (4), then
# prints the unit. Runtime other than native is not supported yet:
# the schema rejects docker until slice 27.
resolve_component() {
	local id="$1"
	in_list "$id" "${COMPONENTS[@]}" || fail 5 "неизвестный компонент: $id"
	component_listed "$id" || fail 4 "компонент не установлен: $id"
	local unit
	unit=$(component_unit "$id")
	[[ "$(component_state "$unit")" != "absent" ]] || fail 4 "компонент не установлен: $id"
	echo "$unit"
}

cmd_control() {
	local verb="$1"
	shift
	[[ $# -eq 1 ]] || fail 2 "$verb: нужен ровно один <id>"
	local unit
	unit=$(resolve_component "$1") || exit $?
	if [[ "$unit" == docker:* ]]; then
		docker_compose_argv
		"${DOCKER_COMPOSE_ARGV[@]}" "$verb" "${unit#docker:}" || fail 1 "$verb $1: docker compose завершился с ошибкой"
		return 0
	fi
	systemctl "$verb" "$unit" || fail 1 "$verb $1: systemctl завершился с ошибкой"
}

# suricata_reload_now - reload the rules of the running Suricata, native
# or in its container.
suricata_reload_now() {
	if [[ "$(component_unit suricata)" == docker:* ]]; then
		docker_suricata_reload
	else
		suricatasc -c ruleset-reload-nonblocking "$(path_suricata_socket)"
	fi
}

cmd_reload() {
	[[ $# -eq 1 ]] || fail 2 "reload: нужен аргумент suricata"
	[[ "$1" == "suricata" ]] || fail 5 "reload: поддерживается только suricata"
	resolve_component suricata >/dev/null || exit $?
	suricata_reload_now ||
		fail 1 "reload suricata: suricatasc завершился с ошибкой"
}

cmd_logs() {
	[[ $# -ge 1 ]] || fail 2 "logs: нужен <id>"
	local id="$1"
	shift
	local n="$LOGS_DEFAULT" follow=0 until_eof=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-n)
			[[ $# -ge 2 ]] || fail 2 "logs: после -n нужно число"
			n="$2"
			shift 2
			;;
		--follow)
			follow=1
			shift
			;;
		--until-stdin-closed)
			# For the panel: it is not root, so it cannot signal sudo to
			# stop us. It holds our stdin open while it listens and closes
			# it to end the stream, which works even when no new line comes.
			follow=1
			until_eof=1
			shift
			;;
		*) fail 2 "logs: неизвестный аргумент: $1" ;;
		esac
	done
	[[ "$n" =~ ^[0-9]{1,6}$ ]] || fail 2 "logs: N должно быть числом"
	# 10#: a leading zero is not octal ("08" is eight, "01750" is 1750).
	n=$((10#$n))
	((n >= 1 && n <= LOGS_MAX)) || fail 2 "logs: N от 1 до $LOGS_MAX"

	local unit
	unit=$(resolve_component "$id") || exit $?
	# logs_argv <follow:0|1> - the command that prints the component's log.
	logs_argv() {
		if [[ "$unit" == docker:* ]]; then
			docker_compose_argv
			LOGS_ARGV=("${DOCKER_COMPOSE_ARGV[@]}" logs --no-color --tail "$n")
			(($1)) && LOGS_ARGV+=(--follow)
			LOGS_ARGV+=("${unit#docker:}")
		else
			LOGS_ARGV=(journalctl -u "$unit" -n "$n" --no-pager)
			(($1)) && LOGS_ARGV+=(--follow)
		fi
		return 0
	}
	local -a LOGS_ARGV
	if ((until_eof)); then
		logs_argv 1
		"${LOGS_ARGV[@]}" &
		local jpid=$!
		# <&0: a background command otherwise gets /dev/null as stdin and
		# would see end of input at once.
		cat <&0 >/dev/null &
		local cpid=$!
		wait -n
		kill "$jpid" "$cpid" 2>/dev/null
		wait 2>/dev/null
		return 0
	fi
	if ((follow)); then
		# No pipe trap: journalctl dies of SIGPIPE when the reader closes.
		logs_argv 1
		"${LOGS_ARGV[@]}"
	else
		logs_argv 0
		"${LOGS_ARGV[@]}"
	fi
}

# ---------------------------------------------------------------- config

# config_path <name> - prints the file behind a name from the 4.5 list.
config_path() {
	case "$1" in
	suricata.yaml) path_suricata_yaml ;;
	evebox.yaml) path_evebox_yaml ;;
	ntopng.conf) path_ntopng_conf ;;
	dpistack.conf) path_conf ;;
	local.rules) path_suricata_local_rules ;;
	enable.conf) path_suricata_enable_conf ;;
	disable.conf) path_suricata_disable_conf ;;
	modify.conf) path_suricata_modify_conf ;;
	drop.conf) path_suricata_drop_conf ;;
	*) return 1 ;;
	esac
}

# ctl_lock / ctl_unlock - the installer's own lock, so a config file is
# never replaced while `install.sh` renders from it. Waits up to 30 s;
# it must not be held while the installer is started (reconfigure).
ctl_lock() {
	local lock_file
	lock_file=$(path_lock_file)
	mkdir -p "$(dirname "$lock_file")"
	exec {CTL_LOCK_FD}>"$lock_file"
	if ! flock -w 30 "$CTL_LOCK_FD"; then
		fail 1 "установщик занят (блокировка $lock_file), повторите позже"
	fi
}

ctl_unlock() {
	exec {CTL_LOCK_FD}>&-
}

# config_commit <name> <staged-file> - backup, then atomic replace.
# Deliberately leaves the render hash in state alone: a file changed
# here counts as edited by hand, so the installer will not overwrite
# it without --force (5.4).
config_commit() {
	local name="$1" staged="$2" path mode
	path=$(config_path "$name")
	ctl_lock
	mode=$(stat -c %a "$path" 2>/dev/null || echo 644)
	backup "$path"
	atomic_write "$path" <"$staged"
	chmod "$mode" "$path"
	ctl_unlock
}

# suricata_check_set <name> <staged-file>
# `suricata -T` on a temporary copy of the set: the live ruleset plus
# the candidate local.rules, with the candidate suricata.yaml when that
# is what changes. Nothing outside the temp dir is touched.
suricata_check_set() {
	local name="$1" staged="$2" tmp yaml rc docker=0 rulepath
	[[ "$(component_unit suricata)" == docker:* ]] && docker=1
	((docker)) || command -v suricata >/dev/null 2>&1 || {
		echo "suricata не установлен" >&2
		return 4
	}
	tmp=$(mktemp -d)
	mkdir -p "$tmp/rules"
	if [[ -f "$(path_suricata_ruleset)" ]]; then
		cp "$(path_suricata_ruleset)" "$tmp/rules/suricata.rules"
	else
		: >"$tmp/rules/suricata.rules"
	fi
	[[ "$name" == "local.rules" ]] && cat "$staged" >>"$tmp/rules/suricata.rules"
	yaml="$(path_suricata_yaml)"
	[[ "$name" == "suricata.yaml" ]] && yaml="$staged"
	# In docker the check runs in the same image the service uses, with the
	# scratch directory mounted at /dpistack-check.
	rulepath="$tmp/rules"
	((docker)) && rulepath="/dpistack-check/rules"
	sed "s#^default-rule-path:.*#default-rule-path: $rulepath#" "$yaml" >"$tmp/suricata.yaml" 2>/dev/null
	if ((docker)); then
		docker_compose_argv
		"${DOCKER_COMPOSE_ARGV[@]}" run --rm --no-deps -v "$tmp:/dpistack-check" suricata -T -c /dpistack-check/suricata.yaml -l /dpistack-check 2>&1
	else
		suricata -T -c "$tmp/suricata.yaml" -l "$tmp" 2>&1
	fi
	rc=$?
	rm -rf "$tmp"
	((rc == 0)) || return 3
	return 0
}

# config_validate_staged <name> <staged-file> - output on stdout,
# returns 0 ok, 3 check failed, 4 component absent.
config_validate_staged() {
	local name="$1" staged="$2"
	case "$name" in
	dpistack.conf)
		# Secrets live in secrets.conf; in dpistack.conf (0644) they would
		# be readable by everyone.
		local line key
		while IFS= read -r line || [[ -n "$line" ]]; do
			key="${line%%=*}"
			if [[ "$line" == *=* && "$line" != \#* ]] && schema_is_secret "$key" 2>/dev/null; then
				echo "$key: секрет хранится в secrets.conf, через config-write его менять нельзя"
				return 3
			fi
		done <"$staged"
		# Schema and cross-field checks of 4.3.
		config_reset
		config_load_defaults
		config_load_kv_file "$staged"
		# Secrets live in their own file; the cross-field checks need them.
		[[ -r "$(path_secrets)" ]] && config_load_kv_file "$(path_secrets)"
		config_validate && return 0
		return 3
		;;
	evebox.yaml | ntopng.conf)
		# A8: neither component has a config-test mode we can rely on,
		# so the only check is that the file is not empty.
		[[ -s "$staged" ]] && return 0
		echo "$name: файл пустой"
		return 3
		;;
	*) suricata_check_set "$name" "$staged" ;;
	esac
}

cmd_config_read() {
	[[ $# -eq 1 ]] || fail 2 "config-read: нужно имя файла"
	local path
	path=$(config_path "$1") || fail 5 "неизвестное имя файла: $1"
	[[ -f "$path" ]] || fail 4 "файл отсутствует: $1"
	cat "$path"
}

# apply_config <name> - reloads whatever reads the file.
apply_config() {
	case "$1" in
	dpistack.conf) ctl_cmd_reconfigure ;;
	suricata.yaml)
		cmd_control restart suricata
		;;
	evebox.yaml)
		cmd_control restart evebox
		;;
	ntopng.conf)
		cmd_control restart ntopng
		;;
	*) cmd_rules_update ;;
	esac
}

cmd_config_write() {
	[[ $# -ge 1 && $# -le 2 ]] || fail 2 "config-write: <имя> [--apply|--check]"
	local name="$1" apply=0 check=0
	config_path "$name" >/dev/null || fail 5 "неизвестное имя файла: $name"
	if [[ $# -eq 2 ]]; then
		case "$2" in
		--apply) apply=1 ;;
		--check) check=1 ;;
		*) fail 2 "config-write: неизвестный аргумент: $2" ;;
		esac
	fi

	local staging staged out rc
	staging=$(path_staging_dir)
	mkdir -p "$staging"
	chmod 0700 "$staging"
	staged="$staging/$name"
	(umask 077 && cat >"$staged")

	out=$(config_validate_staged "$name" "$staged")
	rc=$?
	if ((rc != 0)); then
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out"
		((rc == 4)) && fail 4 "компонент отсутствует"
		fail 3 "$name: проверка не пройдена, файл не изменён"
	fi

	if ((check)); then
		# The panel's "Проверить": the verdict and the checker's own words,
		# and nothing is replaced.
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out"
		echo "$name: проверка пройдена, файл не изменён"
		return 0
	fi

	config_commit "$name" "$staged"
	rm -f "$staged"
	if ((apply)); then
		apply_config "$name" || return $?
	fi
	return 0
}

cmd_config_revert() {
	[[ $# -eq 1 ]] || fail 2 "config-revert: нужно имя файла"
	local name="$1" path latest mode
	path=$(config_path "$name") || fail 5 "неизвестное имя файла: $name"
	latest=$(printf '%s\n' "$(path_backups_dir)/$(basename "$path")".* | sort -V | tail -1)
	[[ -e "$latest" ]] || latest=""
	[[ -n "$latest" ]] || fail 1 "нет бэкапа для $name"
	ctl_lock
	mode=$(stat -c %a "$path" 2>/dev/null || echo 644)
	atomic_write "$path" <"$latest"
	chmod "$mode" "$path"
	ctl_unlock
	echo "восстановлено из $latest"
}

# ctl_cmd_reconfigure [--dry-run] - the installer does the diff, the step
# selection and the re-render; it never installs packages here, because
# --force is not passed and a heavy change stops with code 3.
ctl_cmd_reconfigure() {
	[[ $# -le 1 ]] || fail 2 "reconfigure: лишние аргументы"
	local -a args=(reconfigure -y)
	case "${1:-}" in
	"") ;;
	--dry-run) args+=(--dry-run) ;;
	*) fail 2 "reconfigure: неизвестный аргумент: $1" ;;
	esac
	INSTALLER="$SCRIPT_DIR/install.sh"
	[[ -r "$INSTALLER" ]] || fail 1 "не найден install.sh"

	# -y asks for an explicit ACCESS_CONFIRM when the access mode is not
	# localhost. An unchanged mode is already confirmed; a changed one
	# must go through install.sh reconfigure.
	local applied_access
	applied_access=$(state_read_value "applied.ACCESS_MODE")
	if [[ -n "$applied_access" && "$applied_access" == "$(conf_get ACCESS_MODE localhost)" ]] ||
		[[ "${DPISTACK_ACCESS_CONFIRM:-0}" == "1" ]]; then
		args+=(--set ACCESS_CONFIRM=yes)
	fi

	bash "$INSTALLER" "${args[@]}"
	local rc=$?
	if ((rc == 3)); then
		echo "dpistack: изменение требует переустановки или пересборки, выполните: dpistack reconfigure" >&2
	fi
	return "$rc"
}


# -------------------------------------------------------------- settings
# The dashboard's settings screen (tech.md 9): every key of the schema
# (lib/schema.sh), its value, the checks of config_validate, and the
# application of a change. The panel never edits dpistack.conf as text for
# this; it sends KEY=VALUE pairs.

SETTINGS_UNIT="dpistack-apply"

settings_json_array() {
	local IFS=',' item first=1
	printf '['
	for item in $1; do
		((first)) || printf ','
		first=0
		printf '"%s"' "$(json_escape "$item")"
	done
	printf ']'
}

# settings_lines_json [max] - stdin lines as a JSON array of strings (the
# last <max> of them); no interpreter besides bash.
settings_lines_json() {
	local max="${1:-200}" line first=1
	local -a all=()
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -n "$line" ]] && all+=("$line")
	done
	local n=${#all[@]} i start=0
	((n > max)) && start=$((n - max))
	printf '['
	for ((i = start; i < n; i++)); do
		((first)) || printf ','
		first=0
		printf '"%s"' "$(json_escape "${all[i]}")"
	done
	printf ']'
}

# settings_secret_set <key> - whether secrets.conf holds a value for it.
settings_secret_set() {
	[[ -r "$(path_secrets)" ]] && grep -q "^$1=." "$(path_secrets)"
}

settings_list() {
	local json=0 key first=1 type opts min max value secret set pattern
	[[ "${1:-}" == "--json" ]] && json=1
	if ((json)); then printf '{"keys":['; fi
	for key in "${SCHEMA_KEYS[@]}"; do
		type="${SCHEMA_TYPE[$key]}"
		secret="${SCHEMA_SECRET[$key]}"
		value=""
		set=false
		if [[ "$secret" == "yes" ]]; then
			settings_secret_set "$key" && set=true
		else
			value=$(conf_get "$key" "${SCHEMA_DEFAULT[$key]}")
		fi
		if ((!json)); then
			if [[ "$secret" == "yes" ]]; then
				printf '%s=%s\n' "$key" "$([[ $set == true ]] && echo '(задан)' || echo '(не задан)')"
			else
				printf '%s=%s\n' "$key" "$value"
			fi
			continue
		fi
		((first)) || printf ','
		first=0
		opts="[]"
		min="null"
		max="null"
		if [[ "$type" == "enum" ]]; then
			opts=$(settings_json_array "${SCHEMA_OPTIONS[$key]}")
		elif [[ "$type" == "int" ]]; then
			min="${SCHEMA_OPTIONS[$key]%%..*}"
			max="${SCHEMA_OPTIONS[$key]##*..}"
		fi
		pattern="${SCHEMA_PATTERN[$key]:-}"
		printf '{"key":"%s","type":"%s","options":%s,"min":%s,"max":%s,"default":"%s","level":"%s","group":"%s","weight":"%s","secret":%s,"set":%s,"value":"%s","pattern":"%s"}' \
			"$key" "$type" "$opts" "$min" "$max" "$(json_escape "${SCHEMA_DEFAULT[$key]}")" \
			"${SCHEMA_LEVEL[$key]}" "${SCHEMA_GROUP[$key]}" "${SCHEMA_WEIGHT[$key]}" \
			"$([[ $secret == yes ]] && echo true || echo false)" "$set" \
			"$(json_escape "$value")" "$(json_escape "$pattern")"
	done
	if ((json)); then printf ']}\n'; fi
}

# settings_collect_pairs <args...> - SETTINGS_PAIRS: the KEY=VALUE pairs
# from the arguments, or one per line from stdin when there are none. The
# panel uses stdin: some values (a BPF filter, a rules URL) hold characters
# that the argument check of every verb refuses, and the schema patterns
# are the check that matters for them.
settings_collect_pairs() {
	SETTINGS_PAIRS=()
	local line
	if (($# > 0)); then
		SETTINGS_PAIRS=("$@")
		return 0
	fi
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -n "$line" ]] && SETTINGS_PAIRS+=("$line")
	done
	return 0
}

# settings_stage <KEY=VALUE...> - dpistack.conf with the pairs applied, in
# the staging directory; prints its path. Secrets and unknown keys are
# refused here (code 3) so that no later step has to care.
settings_stage() {
	local staging staged pair key value
	staging=$(path_staging_dir)
	mkdir -p "$staging"
	chmod 0700 "$staging"
	staged="$staging/dpistack.conf"
	cp "$(path_conf)" "$staged"
	for pair in "$@"; do
		[[ "$pair" == *=* ]] || fail 2 "settings: ожидается KEY=VALUE, получено: $pair"
		key="${pair%%=*}"
		value="${pair#*=}"
		schema_known "$key" || fail 5 "неизвестный ключ: $key"
		if schema_is_secret "$key"; then
			fail 3 "$key: секрет, меняется командой settings secret"
		fi
		awk -v k="$key" -v v="$value" 'BEGIN{done=0} index($0, k "=")==1 {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' \
			"$staged" >"$staged.new" && mv "$staged.new" "$staged"
	done
	echo "$staged"
}

# settings_changed <KEY=VALUE...> - the keys whose value differs from the
# current one, one per line.
settings_changed() {
	local pair key
	for pair in "$@"; do
		key="${pair%%=*}"
		[[ "$(conf_get "$key" "${SCHEMA_DEFAULT[$key]}")" == "${pair#*=}" ]] || echo "$key"
	done
}

settings_weight() {
	local key
	for key in "$@"; do
		[[ "${SCHEMA_WEIGHT[$key]}" == "heavy" ]] && {
			echo heavy
			return
		}
	done
	echo light
}

# settings_load_staged <file> - CONF as it will be after the change. The
# validation runs in a command substitution and keeps nothing, so the port
# checks load the staged file themselves.
settings_load_staged() {
	config_reset
	config_load_defaults
	config_load_kv_file "$1"
	[[ -r "$(path_secrets)" ]] && config_load_kv_file "$(path_secrets)"
	return 0
}

# settings_port_warnings <changed keys...> - lines KEY|port|holder|suggestion
# for changed port keys whose port is already taken. Reads CONF as loaded
# from the staged file by config_validate_staged.
settings_port_warnings() {
	local line key
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		key="${line%%|*}"
		in_list "$key" "$@" && echo "$line"
	done < <(preflight_port_conflicts)
}

settings_check() {
	local staged out rc changed weight errors warnings first=1 key port who suggestion kind
	settings_collect_pairs "$@"
	[[ ${#SETTINGS_PAIRS[@]} -ge 1 ]] || fail 2 "settings check: нужен хотя бы один KEY=VALUE"
	staged=$(settings_stage "${SETTINGS_PAIRS[@]}") || exit $?
	changed=$(settings_changed "${SETTINGS_PAIRS[@]}")
	# shellcheck disable=SC2086
	weight=$(settings_weight $changed)
	out=$(config_validate_staged dpistack.conf "$staged")
	rc=$?
	errors="[]"
	if ((rc != 0)); then
		errors=$(printf '%s\n' "$out" | settings_lines_json 50)
	fi
	warnings='['
	if ((rc == 0)); then
		settings_load_staged "$staged"
		# shellcheck disable=SC2086
		while IFS='|' read -r key port who suggestion kind; do
			[[ -z "$key" ]] && continue
			((first)) || warnings+=','
			first=0
			warnings+=$(printf '{"key":"%s","port":%s,"holder":"%s","suggestion":%s,"kind":"%s"}' \
				"$key" "$port" "$(json_escape "$who")" "${suggestion:-null}" "$kind")
		done < <(settings_port_warnings $changed)
	fi
	warnings+=']'
	rm -f "$staged"
	printf '{"ok":%s,"weight":"%s","changed":%s,"errors":%s,"warnings":%s}\n' \
		"$([[ $rc -eq 0 ]] && echo true || echo false)" "$weight" \
		"$(settings_json_array "$(paste -sd, <<<"$changed")")" "$errors" "$warnings"
	return "$rc"
}

settings_set() {
	local mode=commit confirm=0 arg
	local -a pairs=()
	for arg in "$@"; do
		case "$arg" in
		--apply) mode=apply ;;
		--apply-heavy) mode=heavy ;;
		--confirm-access) confirm=1 ;;
		*) pairs+=("$arg") ;;
		esac
	done
	settings_collect_pairs "${pairs[@]}"
	pairs=("${SETTINGS_PAIRS[@]}")
	[[ ${#pairs[@]} -ge 1 ]] || fail 2 "settings set: нужен хотя бы один KEY=VALUE"
	local staged out rc changed weight warn
	staged=$(settings_stage "${pairs[@]}") || exit $?
	changed=$(settings_changed "${pairs[@]}")
	if [[ -z "$changed" ]]; then
		rm -f "$staged"
		echo "без изменений"
		return 0
	fi
	# shellcheck disable=SC2086
	weight=$(settings_weight $changed)
	out=$(config_validate_staged dpistack.conf "$staged")
	rc=$?
	if ((rc != 0)); then
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out"
		fail 3 "settings: проверка не пройдена, dpistack.conf не изменён"
	fi
	# A busy port is a stop with a way out: the holder and a free port.
	settings_load_staged "$staged"
	# shellcheck disable=SC2086
	warn=$(settings_port_warnings $changed | head -n 1)
	if [[ -n "$warn" ]]; then
		local key port who suggestion
		IFS='|' read -r key port who suggestion _ <<<"$warn"
		rm -f "$staged"
		fail 3 "порт $port ($key) уже занят: $who${suggestion:+; свободный: $suggestion}"
	fi
	if [[ "$weight" == "heavy" && "$mode" == "apply" ]]; then
		rm -f "$staged"
		fail 3 "тяжёлое изменение ($(paste -sd, <<<"$changed")): нужен --apply-heavy"
	fi
	if ((confirm)); then
		DPISTACK_ACCESS_CONFIRM=1
		export DPISTACK_ACCESS_CONFIRM
	fi
	config_commit dpistack.conf "$staged"
	rm -f "$staged"
	case "$mode" in
	commit) echo "dpistack.conf записан, не применён" ;;
	apply)
		if ! ctl_cmd_reconfigure; then
			cmd_config_revert dpistack.conf >/dev/null
			fail 1 "reconfigure не удался, dpistack.conf возвращён"
		fi
		;;
	heavy) settings_start_job "$confirm" ;;
	esac
}

# settings_start_job <confirm-access> - the heavy reconfigure runs as a
# transient unit: packages and builds take minutes, longer than a request.
settings_start_job() {
	local -a args=(reconfigure -y --force)
	[[ "$1" == "1" ]] && args+=(--set ACCESS_CONFIRM=yes)
	case "$(systemctl is-active "$SETTINGS_UNIT.service" 2>/dev/null)" in
	active | activating) fail 3 "применение уже идёт" ;;
	esac
	systemctl reset-failed "$SETTINGS_UNIT.service" >/dev/null 2>&1 || true
	systemd-run --quiet --unit="$SETTINGS_UNIT" --description="dpistack: применение настроек" \
		--collect "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null ||
		fail 1 "не удалось запустить применение"
	echo "применение запущено: $SETTINGS_UNIT"
}

settings_job() {
	local state result lines
	state=$(systemctl is-active "$SETTINGS_UNIT.service" 2>/dev/null || true)
	[[ -n "$state" ]] || state=unknown
	result=$(systemctl show -p Result --value "$SETTINGS_UNIT.service" 2>/dev/null || true)
	lines=$(journalctl -u "$SETTINGS_UNIT.service" -n 200 --no-pager -o cat 2>/dev/null | settings_lines_json 200)
	printf '{"state":"%s","result":"%s","log":%s}\n' "$(json_escape "$state")" "$(json_escape "${result:-}")" "$lines"
}

# settings_secret <KEY> - the value comes on stdin and never in an argument.
settings_secret() {
	[[ $# -eq 1 ]] || fail 2 "settings secret: нужен KEY"
	local key="$1" value tmp
	if ! schema_known "$key" || ! schema_is_secret "$key"; then
		fail 5 "$key: не секрет схемы"
	fi
	IFS= read -r value || true
	if [[ -n "$value" ]]; then
		schema_validate_one "$key" "$value" >/dev/null || fail 3 "$key: значение не подходит"
	fi
	ctl_lock
	tmp=$(mktemp)
	if [[ -r "$(path_secrets)" ]]; then
		grep -v "^$key=" "$(path_secrets)" >"$tmp" || true
	fi
	if [[ -n "$value" ]]; then
		printf '%s=%s\n' "$key" "$value" >>"$tmp"
	fi
	atomic_write "$(path_secrets)" 0600 <"$tmp"
	rm -f "$tmp"
	ctl_unlock
	if ! ctl_cmd_reconfigure; then
		fail 1 "reconfigure не удался, секрет записан"
	fi
}

cmd_settings() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	list) settings_list "$@" ;;
	check) settings_check "$@" ;;
	set) settings_set "$@" ;;
	secret) settings_secret "$@" ;;
	job) settings_job ;;
	*) fail 2 "settings: list [--json] | check KEY=VALUE... | set [--apply|--apply-heavy] [--confirm-access] KEY=VALUE... | secret KEY | job" ;;
	esac
}

# ----------------------------------------------------------------- iface

# iface_set_list <comma-list> - writes IFACES into dpistack.conf and
# applies it; a failed apply puts the previous file back.
# conf_apply_value <KEY> <value> - one key of dpistack.conf: checked as a
# whole, committed with a backup, applied by reconfigure; the old file comes
# back when reconfigure fails.
conf_apply_value() {
	local key="$1" value="$2" staging staged out rc
	staging=$(path_staging_dir)
	mkdir -p "$staging"
	chmod 0700 "$staging"
	staged="$staging/dpistack.conf"
	awk -v k="$key" -v v="$value" 'BEGIN{done=0} $0 ~ "^" k "=" {print k "=" v; done=1; next} {print} END{if(!done) print k "=" v}' \
		"$(path_conf)" >"$staged"

	out=$(config_validate_staged dpistack.conf "$staged")
	rc=$?
	if ((rc != 0)); then
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out"
		fail 3 "$key: проверка не пройдена, файл не изменён"
	fi
	config_commit dpistack.conf "$staged"
	rm -f "$staged"
	if ! ctl_cmd_reconfigure; then
		cmd_config_revert dpistack.conf >/dev/null
		fail 1 "reconfigure не удался, dpistack.conf возвращён"
	fi
}

iface_set_list() { conf_apply_value IFACES "$1"; }

# --------------------------------------------------------------- IPS mode

mode_now() { "${DPISTACK_NOW_CMD:-date}" +%s; }

# mode_pending_deadline - epoch seconds of the rollback, empty when none.
mode_pending_deadline() {
	sed -n 's/^deadline=//p' "$(path_mode_pending)" 2>/dev/null | head -1
}

mode_cancel_timer() {
	systemctl stop "${MODE_ROLLBACK_UNIT}.timer" "${MODE_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
	# A rollback service that failed stays loaded under the same name, and
	# the next systemd-run --unit=... would be refused ("already loaded").
	systemctl reset-failed "${MODE_ROLLBACK_UNIT}.timer" "${MODE_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
}

# mode_check_ips_possible - everything IPS needs, or the refusal (code 3).
mode_check_ips_possible() {
	[[ "$(conf_get SURICATA_RUNTIME native)" == "native" ]] ||
		fail 3 "mode ips: только для SURICATA_RUNTIME=native"
	if [[ "$(conf_get IPS_METHOD nfq)" == "nfq" ]]; then
		[[ -n "$(ips_backend)" ]] || fail 3 "mode ips: не найдены ни iptables, ни nft (нужны для очереди NFQUEUE)"
	fi
	command -v suricata >/dev/null 2>&1 || fail 4 "mode ips: suricata не установлена"
}

# mode_drop_rules_present - something can drop: a "drop" or "reject" rule in
# local.rules, or a line in drop.conf (suricata-update turns the rules it
# names into drop). Without either IPS only alerts, like IDS.
mode_drop_rules_present() {
	grep -Eqs '^[[:space:]]*(drop|reject)[[:space:]]' "$(path_suricata_local_rules)" && return 0
	grep -Eqs '^[[:space:]]*[^#[:space:]]' "$(path_suricata_drop_conf)"
}

mode_go_ids() {
	mode_cancel_timer
	rm -f "$(path_mode_pending)"
	# The rules go first: with no NFQUEUE jump, nothing waits for Suricata
	# while it restarts in ids mode.
	ips_fw_remove
	if [[ "$(conf_get SURICATA_MODE ids)" != "ids" ]]; then
		conf_apply_value SURICATA_MODE ids
	fi
}

cmd_mode_status() {
	local json=0
	[[ "${1:-}" == "--json" ]] && json=1
	local mode method deadline now remaining=0 pending=false
	mode=$(conf_get SURICATA_MODE ids)
	method=$(conf_get IPS_METHOD nfq)
	deadline=$(mode_pending_deadline)
	if [[ -n "$deadline" ]]; then
		now=$(mode_now)
		remaining=$((deadline - now))
		((remaining < 0)) && remaining=0
		pending=true
	fi
	if ((json)); then
		printf '{"mode":"%s","method":"%s","pending":%s,"remaining_sec":%d}\n' "$mode" "$method" "$pending" "$remaining"
	else
		echo "режим: $mode (метод $method)"
		[[ "$pending" == "true" ]] && echo "ожидает mode-confirm: ${remaining} с до отката в ids"
	fi
	return 0
}

cmd_mode() {
	[[ $# -ge 1 ]] || fail 2 "mode: ids|ips|status"
	local target="$1"
	shift
	case "$target" in
	status)
		cmd_mode_status "$@"
		return
		;;
	ids | ips) ;;
	*) fail 2 "mode: ids|ips|status" ;;
	esac

	local timeout="$MODE_TIMEOUT_DEFAULT"
	while (($# > 0)); do
		case "$1" in
		--confirm-timeout)
			[[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail 2 "mode: --confirm-timeout требует число секунд"
			timeout="$2"
			shift 2
			;;
		*) fail 2 "mode: неизвестный аргумент: $1" ;;
		esac
	done
	((timeout >= MODE_TIMEOUT_MIN && timeout <= MODE_TIMEOUT_MAX)) ||
		fail 2 "mode: --confirm-timeout от $MODE_TIMEOUT_MIN до $MODE_TIMEOUT_MAX секунд"

	if [[ "$target" == "ids" ]]; then
		mode_go_ids
		echo "режим ids"
		return 0
	fi

	mode_check_ips_possible
	if [[ "$(conf_get SURICATA_MODE ids)" == "ips" && -z "$(mode_pending_deadline)" ]]; then
		echo "уже в режиме ips"
		return 0
	fi

	# Suricata restarts in ips first; only then do the rules start sending
	# it traffic. --queue-bypass is there for the time it is down.
	mode_cancel_timer
	conf_apply_value SURICATA_MODE ips
	if [[ "$(conf_get IPS_METHOD nfq)" == "nfq" ]]; then
		if ! ips_fw_apply "$(conf_get IPS_NFQ_CHAINS INPUT,OUTPUT,FORWARD)"; then
			ips_fw_remove
			conf_apply_value SURICATA_MODE ids
			fail 1 "mode ips: правила файрвола не применились, режим возвращён в ids"
		fi
	fi

	local deadline
	deadline=$(($(mode_now) + timeout))
	mkdir -p "$(path_state_dir)"
	printf 'deadline=%s\n' "$deadline" >"$(path_mode_pending)"
	if ! systemd-run --unit="$MODE_ROLLBACK_UNIT" --on-active="${timeout}s" --timer-property=AccuracySec=1s \
		"$(path_ctl_bin)" mode-rollback >/dev/null 2>&1; then
		# Without a timer there is nothing to bring the host back.
		mode_go_ids
		fail 1 "mode ips: не удалось запустить таймер отката, режим возвращён в ids"
	fi
	echo "режим ips включён; подтвердите командой mode-confirm в течение ${timeout} с, иначе вернётся ids"
	mode_drop_rules_present ||
		echo "предупреждение: правил drop нет (ни в local.rules, ни в drop.conf), IPS будет только оповещать, как IDS"
}

cmd_mode_confirm() {
	[[ $# -eq 0 ]] || fail 2 "mode-confirm: без аргументов"
	local deadline
	deadline=$(mode_pending_deadline)
	[[ -n "$deadline" ]] || fail 3 "mode-confirm: нечего подтверждать (переключения в ips нет или оно уже откатилось)"
	if (($(mode_now) > deadline)); then
		fail 3 "mode-confirm: время подтверждения истекло, режим возвращается в ids"
	fi
	mode_cancel_timer
	rm -f "$(path_mode_pending)"
	echo "режим ips подтверждён"
}

# mode-rollback runs from the timer (and at boot): an unconfirmed switch
# goes back to ids, the DPISTACK rules go away.
cmd_mode_rollback() {
	[[ -n "$(mode_pending_deadline)" ]] || return 0
	mode_go_ids
	echo "режим ips не подтверждён, возвращён ids"
}

cmd_fw() {
	[[ $# -eq 1 ]] || fail 2 "fw: apply|remove|restore"
	case "$1" in
	apply)
		ips_fw_apply "$(conf_get IPS_NFQ_CHAINS INPUT,OUTPUT,FORWARD)" || fail 1 "fw apply: файрвол отказал"
		;;
	remove) ips_fw_remove ;;
	restore)
		# Boot: an unconfirmed switch did not survive the reboot, the rest
		# is put back as the config says.
		if [[ -n "$(mode_pending_deadline)" ]]; then
			cmd_mode_rollback
		elif [[ "$(conf_get SURICATA_MODE ids)" == "ips" && "$(conf_get IPS_METHOD nfq)" == "nfq" ]]; then
			ips_fw_apply "$(conf_get IPS_NFQ_CHAINS INPUT,OUTPUT,FORWARD)" || fail 1 "fw restore: файрвол отказал"
		elif ips_fw_present; then
			ips_fw_remove
		fi
		;;
	*) fail 2 "fw: apply|remove|restore" ;;
	esac
}

cmd_iface() {
	[[ $# -ge 1 ]] || fail 2 "iface: list|add|remove"
	local sub="$1"
	shift
	local -a current=()
	IFS=',' read -ra current <<<"$(conf_get IFACES enp2s0)"

	case "$sub" in
	list)
		[[ $# -eq 0 ]] || fail 2 "iface list: без аргументов"
		printf '%s\n' "${current[@]}"
		;;
	add)
		[[ $# -eq 1 ]] || fail 2 "iface add: нужно имя интерфейса"
		if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$ ]] || ! ip link show "$1" >/dev/null 2>&1; then
			fail 5 "интерфейса нет в системе: $1"
		fi
		if in_list "$1" "${current[@]}"; then
			echo "уже в списке: $1"
			return 0
		fi
		current+=("$1")
		iface_set_list "$(
			IFS=,
			echo "${current[*]}"
		)"
		;;
	remove)
		[[ $# -eq 1 ]] || fail 2 "iface remove: нужно имя интерфейса"
		in_list "$1" "${current[@]}" || fail 5 "интерфейса нет в IFACES: $1"
		((${#current[@]} > 1)) || fail 3 "нельзя удалить последний интерфейс"
		local -a rest=() i
		for i in "${current[@]}"; do
			[[ "$i" == "$1" ]] || rest+=("$i")
		done
		iface_set_list "$(
			IFS=,
			echo "${rest[*]}"
		)"
		;;
	*) fail 2 "iface: неизвестная подкоманда: $sub" ;;
	esac
}

# ----------------------------------------------------------------- rules

# rules_edit_line <name> add|remove <line> - one exact line in a
# suricata-update input file, through the same backup and atomic
# replace as config-write.
rules_edit_line() {
	local name="$1" op="$2" line="$3" path staging staged
	path=$(config_path "$name")
	staging=$(path_staging_dir)
	mkdir -p "$staging"
	chmod 0700 "$staging"
	staged="$staging/$name"
	if [[ -f "$path" ]]; then
		grep -vxF -- "$line" "$path" >"$staged" || true
	else
		: >"$staged"
	fi
	[[ "$op" == "add" ]] && printf '%s\n' "$line" >>"$staged"
	config_commit "$name" "$staged"
	rm -f "$staged"
}

cmd_rules_group() {
	[[ $# -eq 2 ]] || fail 2 "rules-group: enable|disable <группа>"
	[[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 5 "недопустимое имя группы"
	case "$1" in
	enable) rules_edit_line enable.conf add "group:$2.rules" ;;
	disable) rules_edit_line enable.conf remove "group:$2.rules" ;;
	*) fail 2 "rules-group: enable|disable" ;;
	esac
}

cmd_rules_sid() {
	[[ $# -eq 2 ]] || fail 2 "rules-sid: enable|disable <sid>"
	[[ "$2" =~ ^[0-9]+$ ]] || fail 5 "sid должен быть числом"
	case "$1" in
	disable) rules_edit_line disable.conf add "$2" ;;
	enable) rules_edit_line disable.conf remove "$2" ;;
	*) fail 2 "rules-sid: enable|disable" ;;
	esac
}

cmd_rules_sources() {
	[[ $# -ge 1 ]] || fail 2 "rules-sources: list|enable|disable|add-url|remove"
	local sub="$1" data_dir
	shift
	data_dir=$(path_rules_data_dir)
	command -v suricata-update >/dev/null 2>&1 || fail 4 "suricata-update не установлен"
	case "$sub" in
	list)
		if [[ $# -eq 1 && "$1" == "--enabled" ]]; then
			suricata-update list-enabled-sources -D "$data_dir"
			return
		fi
		[[ $# -eq 0 ]] || fail 2 "rules-sources list: без аргументов или --enabled"
		suricata-update list-sources -D "$data_dir"
		;;
	enable | disable | remove)
		[[ $# -eq 1 ]] || fail 2 "rules-sources $sub: нужно имя источника"
		# No leading "-": the name goes to suricata-update as an argument and
		# would be read as an option.
		[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail 5 "недопустимое имя источника"
		suricata-update "$sub-source" -D "$data_dir" "$1"
		;;
	add-url)
		[[ $# -eq 1 ]] || fail 2 "rules-sources add-url: нужен URL"
		[[ "$1" =~ ^https?://[A-Za-z0-9._:/@+,=-]+$ ]] || fail 5 "недопустимый URL"
		suricata-update add-source -D "$data_dir" \
			"dpistack-custom-$(printf '%s' "$1" | sha256sum | cut -c1-8)" "$1"
		;;
	*) fail 2 "rules-sources: неизвестная подкоманда: $sub" ;;
	esac
}

cmd_rules_search() {
	[[ $# -eq 1 && -n "$1" ]] || fail 2 "rules-search: нужен один запрос"
	local ruleset
	ruleset=$(path_suricata_ruleset)
	[[ -f "$ruleset" ]] || fail 4 "набор правил отсутствует"
	# A number matches the sid exactly, anything else matches msg text.
	RULES_Q="$1" awk -v max="$RULES_SEARCH_MAX" '
		BEGIN { q = tolower(ENVIRON["RULES_Q"]); num = (q ~ /^[0-9]+$/) }
		/^[ \t]*#/ { next }
		{
			sid = ""; msg = ""
			if (match($0, /sid: *[0-9]+/)) { sid = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", sid) }
			if (match($0, /msg: *"[^"]*"/)) { msg = substr($0, RSTART, RLENGTH); sub(/^msg: *"/, "", msg); sub(/"$/, "", msg) }
			if (sid == "") next
			if (num ? (sid == q) : (index(tolower(msg), q) > 0)) {
				print sid "\t" msg
				if (++n >= max) exit
			}
		}' "$ruleset"
}

# cmd_rules_update - snapshot, suricata-update, suricata -T, reload;
# any failure puts the previous ruleset back. What the tools said goes to
# stdout (the last RULES_UPDATE_TAIL lines) on success and on failure, so
# the panel can show the reason: its caller keeps only the first line of
# stderr, which for suricata-update is a log header, not the cause.
RULES_UPDATE_TAIL=40

cmd_rules_update() {
	[[ $# -eq 0 ]] || fail 2 "rules-update: без аргументов"
	command -v suricata-update >/dev/null 2>&1 || fail 4 "suricata-update не установлен"
	local ruleset snap log
	ruleset=$(path_suricata_ruleset)
	snap=$(mktemp)
	log=$(mktemp)
	if [[ -f "$ruleset" ]]; then
		cp -p "$ruleset" "$snap"
	else
		rm -f "$snap"
		snap=""
	fi

	local ok=1
	rules_update_argv
	"${RULES_UPDATE_ARGV[@]}" >"$log" 2>&1 || ok=0
	if ((ok)) && [[ "$(component_unit suricata)" == docker:* ]]; then
		if ! docker_suricata_test >>"$log" 2>&1; then
			echo "suricata -T не принял новый набор правил" >>"$log"
			ok=0
		fi
	elif ((ok)) && command -v suricata >/dev/null 2>&1; then
		local check_dir
		check_dir=$(mktemp -d)
		if ! suricata -T -c "$(path_suricata_yaml)" -l "$check_dir" >>"$log" 2>&1; then
			echo "suricata -T не принял новый набор правил" >>"$log"
			ok=0
		fi
		rm -rf "$check_dir"
	fi
	if ((ok)); then
		suricata_reload_now >>"$log" 2>&1 || {
			echo "перезагрузка правил не удалась" >>"$log"
			ok=0
		}
	fi
	tail -n "$RULES_UPDATE_TAIL" "$log"
	rm -f "$log"

	if ((!ok)); then
		if [[ -n "$snap" ]]; then
			cp -p "$snap" "$ruleset"
			rm -f "$snap"
		fi
		fail 1 "rules-update не удался, прежний набор правил возвращён"
	fi
	[[ -n "$snap" ]] && rm -f "$snap"
	return 0
}

# ------------------------------------------------------------------ test

cmd_test() {
	[[ $# -ge 1 && $# -le 2 ]] || fail 2 "test: bittorrent|https|all [--json]"
	local which="$1" json=0
	if [[ $# -eq 2 ]]; then
		[[ "$2" == "--json" ]] || fail 2 "test: неизвестный аргумент: $2"
		json=1
	fi
	local -a names
	case "$which" in
	bittorrent | https) names=("$which") ;;
	all) names=("${VERIFY_TESTS[@]}") ;;
	*) fail 5 "неизвестный тест: $which" ;;
	esac
	# shellcheck disable=SC2034 # read by lib/step_verify.sh
	VERIFY_HTTPS_URL=$(conf_get TEST_HTTPS_URL https://example.com)
	# shellcheck disable=SC2034 # read by lib/step_verify.sh
	VERIFY_BT_LIVE=$(conf_get TEST_BT_LIVE no)
	# shellcheck disable=SC2034 # read by lib/step_verify.sh
	VERIFY_IFACES=$(conf_get IFACES enp2s0)
	verify_run "$json" "${names[@]}" || exit 1
}

# ---------------------------------------------------------------- health

# cmd_health - one watchdog run, then the same JSON it wrote.
cmd_health() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "health: неизвестный аргумент" ;;
	esac
	[[ $# -le 1 ]] || fail 2 "health: лишние аргументы"
	local watch="$SCRIPT_DIR/bin/dpistack-watch"
	[[ -x "$watch" ]] || fail 4 "dpistack-watch не установлен"
	"$watch" || fail 1 "health: dpistack-watch завершился с ошибкой"
	local file
	file=$(path_health_json)
	[[ -f "$file" ]] || fail 1 "health: $file не создан"
	if ((json)); then
		cat "$file"
	else
		jq -r '"overall: \(.overall)  (\(.ts))", (.checks[] | "\(.id)\t\(.status)\t\(.value)\t\(.detail)")' "$file" || fail 1 "health: нужен jq"
	fi
}

# ----------------------------------------------------------- panel-passwd

cmd_panel_passwd() {
	[[ $# -eq 0 ]] || fail 2 "panel-passwd: пароль читается со stdin"
	local pw=""
	IFS= read -r pw || true
	[[ -n "$pw" ]] || fail 2 "panel-passwd: пустой пароль"
	command -v argon2 >/dev/null 2>&1 || fail 1 "не установлен пакет argon2"
	panel_auth_write "$pw" || fail 1 "не удалось записать хэш пароля"
	echo "пароль панели обновлён"
}

ctl_main() {
	if [[ $# -eq 0 ]]; then
		ctl_usage
		exit 2
	fi

	# Every argument is checked before any command runs (4.5).
	local arg
	for arg in "$@"; do
		[[ "$arg" =~ ^[A-Za-z0-9._:=/@+,\ -]*$ ]] || fail 5 "недопустимые символы в аргументе"
	done

	local cmd="$1"
	shift
	case "$cmd" in
	status) ctl_cmd_status "$@" ;;
	start | stop | restart) cmd_control "$cmd" "$@" ;;
	reload) cmd_reload "$@" ;;
	logs) cmd_logs "$@" ;;
	config-read) cmd_config_read "$@" ;;
	config-write) cmd_config_write "$@" ;;
	config-revert) cmd_config_revert "$@" ;;
	settings) cmd_settings "$@" ;;
	reconfigure) ctl_cmd_reconfigure "$@" ;;
	rules-update) cmd_rules_update "$@" ;;
	rules-sources) cmd_rules_sources "$@" ;;
	rules-group) cmd_rules_group "$@" ;;
	rules-sid) cmd_rules_sid "$@" ;;
	rules-search) cmd_rules_search "$@" ;;
	iface) cmd_iface "$@" ;;
	mode) cmd_mode "$@" ;;
	mode-confirm) cmd_mode_confirm "$@" ;;
	mode-rollback) cmd_mode_rollback "$@" ;;
	fw) cmd_fw "$@" ;;
	panel-passwd) cmd_panel_passwd "$@" ;;
	test) cmd_test "$@" ;;
	health) cmd_health "$@" ;;
	version) echo "$DPISTACK_VERSION" ;;
	*)
		ctl_usage >&2
		exit 2
		;;
	esac
}
