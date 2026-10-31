#!/usr/bin/env bash
# The privileged verbs of dpistack (tech.md 4.5): status, start, stop, config
# editing, rules, interfaces, mode, tests, health, panel password. They are
# part of the one `dpistack` command (install.sh dispatches here); the panel
# and the watchdog reach them through `sudo -n dpistack <verb>`. Sourced by
# install.sh after the other libraries; it defines functions only.
#
# Exit codes: 0 ok, 1 error, 2 usage, 3 check failed, 4 component
# absent, 5 name outside the allowed list.

COMPONENTS=(suricata evebox ntopng redis victoriametrics prometheus node_exporter grafana panel watch rules)
LOGS_MAX=1000
LOGS_DEFAULT=100

MODE_TIMEOUT_DEFAULT=120
MODE_TIMEOUT_MIN=10
MODE_TIMEOUT_MAX=3600
MODE_ROLLBACK_UNIT="dpistack-mode-rollback"

RULES_SEARCH_MAX=50

ctl_usage() {
	cat <<'USAGE'
Usage: dpistack <command> [arguments]

  status [--json]                    component state
  start|stop|restart <id>            control a component
  reload suricata                    reload the rules without stopping
  logs <id> [-n N] [--follow]        component log, N up to 1000 (--until-stdin-closed: for the panel)
  config-read <name>                 prints the current file
  config-write <name> [--apply|--check] new content from stdin; --check only validates
  settings list [--json] | check K=V... | set [--apply|--apply-heavy] [--confirm-access] K=V... | secret KEY | job
  config-revert <name>               restores the latest backup
  reconfigure [--dry-run]            applies the current dpistack.conf
  rules-update                       update the rules, roll back on error
  rules-sources list [--enabled]|enable|disable|add-url|remove [arg]
  rules-group enable|disable <group>
  rules-sid enable|disable <sid>
  rules-search <query>              up to 50 rules by sid or msg
  iface list|add|remove [name]        capture interfaces
  mode ids|ips [--confirm-timeout S] Suricata mode; ips rolls back by itself without mode-confirm (default 120 s)
  mode status [--json]               mode, method and countdown
  mode-confirm                       confirm the switch to ips
  fw apply|remove|restore            DPISTACK chain (restore: at boot)
  panel-passwd                       panel password from stdin
  test bittorrent|https|all [--json] check tests (section 10)
  health [--json]                    one watchdog run
  users list|add|passwd|role|disable|enable|remove  users of the panel (passwords on stdin)
  runtime [--json]                   what can run in docker, the runtime of every part, the links between them
  version                            bundle version

Config names: suricata.yaml evebox.yaml ntopng.conf dpistack.conf local.rules
                enable.conf disable.conf modify.conf drop.conf

Components: suricata evebox ntopng redis victoriametrics prometheus node_exporter grafana panel watch rules
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
	if [[ "$1" =~ ^(suricata|evebox|ntopng|redis|victoriametrics|prometheus|node_exporter|grafana|panel)$ && "$(component_runtime "$1")" == "docker" ]]; then
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
	node_exporter) echo "dpistack-node-exporter.service" ;;
	grafana) echo "dpistack-grafana.service" ;;
	panel) echo "dpistack-panel.service" ;;
	watch) echo "dpistack-watch.timer" ;;
	rules) echo "dpistack-rules.timer" ;;
	esac
}

# component_listed <id> - backend components exist only when selected; a
# part that is switched off (*_ENABLE=no) is left out of status and health
# unless it is installed anyway (switching off does not remove it).
component_listed() {
	local key=""
	case "$1" in
	suricata) key=SURICATA_ENABLE ;;
	rules) key=RULES_ENABLE ;;
	evebox) key=EVEBOX_ENABLE ;;
	ntopng | redis) key=NTOPNG_ENABLE ;;
	panel) key=PANEL_ENABLE ;;
	esac
	if [[ -n "$key" && "$(conf_get "$key" yes)" == "no" ]]; then
		unit_loaded "$(component_unit "$1")"
		return
	fi
	case "$1" in
	victoriametrics | prometheus)
		[[ "$(conf_get METRICS_BACKEND none)" == "$1" ]]
		;;
	node_exporter) [[ "$(conf_get NODE_EXPORTER_ENABLE no)" == "yes" ]] ;;
	grafana) [[ "$(conf_get GRAFANA_ENABLE no)" == "yes" ]] ;;
	*) return 0 ;;
	esac
}

component_runtime() {
	case "$1" in
	suricata) conf_get SURICATA_RUNTIME native ;;
	evebox) conf_get EVEBOX_RUNTIME native ;;
	ntopng | redis) conf_get NTOPNG_RUNTIME native ;;
	victoriametrics | prometheus) conf_get METRICS_BACKEND_RUNTIME native ;;
	node_exporter) conf_get NODE_EXPORTER_RUNTIME native ;;
	grafana) conf_get GRAFANA_RUNTIME native ;;
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
	*) fail 2 "status: unknown argument" ;;
	esac
	[[ $# -le 1 ]] || fail 2 "status: extra arguments"

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
	in_list "$id" "${COMPONENTS[@]}" || fail 5 "unknown component: $id"
	component_listed "$id" || fail 4 "component not installed: $id"
	local unit
	unit=$(component_unit "$id")
	[[ "$(component_state "$unit")" != "absent" ]] || fail 4 "component not installed: $id"
	echo "$unit"
}

cmd_control() {
	local verb="$1"
	shift
	[[ $# -eq 1 ]] || fail 2 "$verb: exactly one <id> is needed"
	local unit
	unit=$(resolve_component "$1") || exit $?
	if [[ "$unit" == docker:* ]]; then
		docker_compose_argv
		"${DOCKER_COMPOSE_ARGV[@]}" "$verb" "${unit#docker:}" || fail 1 "$verb $1: docker compose failed"
		return 0
	fi
	systemctl "$verb" "$unit" || fail 1 "$verb $1: systemctl failed"
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
	[[ $# -eq 1 ]] || fail 2 "reload: the argument suricata is needed"
	[[ "$1" == "suricata" ]] || fail 5 "reload: only suricata is supported"
	resolve_component suricata >/dev/null || exit $?
	suricata_reload_now ||
		fail 1 "reload suricata: suricatasc failed"
}

cmd_logs() {
	[[ $# -ge 1 ]] || fail 2 "logs: <id> is needed"
	local id="$1"
	shift
	local n="$LOGS_DEFAULT" follow=0 until_eof=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-n)
			[[ $# -ge 2 ]] || fail 2 "logs: -n needs a number"
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
		*) fail 2 "logs: unknown argument: $1" ;;
		esac
	done
	[[ "$n" =~ ^[0-9]{1,6}$ ]] || fail 2 "logs: N must be a number"
	# 10#: a leading zero is not octal ("08" is eight, "01750" is 1750).
	n=$((10#$n))
	((n >= 1 && n <= LOGS_MAX)) || fail 2 "logs: N from 1 to $LOGS_MAX"

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
		fail 1 "the installer is busy (lock $lock_file), try again later"
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
		echo "suricata is not installed" >&2
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
				echo "$key: a secret is kept in secrets.conf and cannot be changed through config-write"
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
		echo "$name: the file is empty"
		return 3
		;;
	*) suricata_check_set "$name" "$staged" ;;
	esac
}

cmd_config_read() {
	[[ $# -eq 1 ]] || fail 2 "config-read: a file name is needed"
	local path
	path=$(config_path "$1") || fail 5 "unknown file name: $1"
	[[ -f "$path" ]] || fail 4 "file missing: $1"
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
	[[ $# -ge 1 && $# -le 2 ]] || fail 2 "config-write: <name> [--apply|--check]"
	local name="$1" apply=0 check=0
	config_path "$name" >/dev/null || fail 5 "unknown file name: $name"
	if [[ $# -eq 2 ]]; then
		case "$2" in
		--apply) apply=1 ;;
		--check) check=1 ;;
		*) fail 2 "config-write: unknown argument: $2" ;;
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
		((rc == 4)) && fail 4 "component missing"
		fail 3 "$name: check failed, file unchanged"
	fi

	if ((check)); then
		# The panel's "Check": the verdict and the checker's own words,
		# and nothing is replaced.
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out"
		echo "$name: check passed, file unchanged"
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
	[[ $# -eq 1 ]] || fail 2 "config-revert: a file name is needed"
	local name="$1" path latest mode
	path=$(config_path "$name") || fail 5 "unknown file name: $name"
	latest=$(printf '%s\n' "$(path_backups_dir)/$(basename "$path")".* | sort -V | tail -1)
	[[ -e "$latest" ]] || latest=""
	[[ -n "$latest" ]] || fail 1 "no backup for $name"
	ctl_lock
	mode=$(stat -c %a "$path" 2>/dev/null || echo 644)
	atomic_write "$path" <"$latest"
	chmod "$mode" "$path"
	ctl_unlock
	echo "restored from $latest"
}

# ctl_cmd_reconfigure [--dry-run] - the installer does the diff, the step
# selection and the re-render; it never installs packages here, because
# --force is not passed and a heavy change stops with code 3.
ctl_cmd_reconfigure() {
	[[ $# -le 1 ]] || fail 2 "reconfigure: extra arguments"
	local -a args=(reconfigure -y)
	case "${1:-}" in
	"") ;;
	--dry-run) args+=(--dry-run) ;;
	*) fail 2 "reconfigure: unknown argument: $1" ;;
	esac
	INSTALLER="$SCRIPT_DIR/install.sh"
	[[ -r "$INSTALLER" ]] || fail 1 "install.sh not found"

	# -y asks for an explicit ACCESS_CONFIRM when the access mode is not
	# localhost. An unchanged mode is already confirmed; a changed one
	# must go through install.sh reconfigure.
	local applied_access applied_bind
	applied_access=$(state_read_value "applied.ACCESS_MODE")
	applied_bind=$(state_read_value "applied.BIND_ADDR")
	if [[ -n "$applied_access" && "$applied_access" == "$(conf_get ACCESS_MODE localhost)" &&
	"${applied_bind:-auto}" == "$(conf_get BIND_ADDR auto)" ]] ||
		[[ "${DPISTACK_ACCESS_CONFIRM:-0}" == "1" ]]; then
		args+=(--set ACCESS_CONFIRM=yes)
	fi

	bash "$INSTALLER" "${args[@]}"
	local rc=$?
	if ((rc == 3)); then
		echo "dpistack: this change needs a reinstall or rebuild, run: dpistack reconfigure" >&2
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
		if ((json == 0)); then
			if [[ "$secret" == "yes" ]]; then
				printf '%s=%s\n' "$key" "$([[ $set == true ]] && echo '(set)' || echo '(not set)')"
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
		[[ "$pair" == *=* ]] || fail 2 "settings: KEY=VALUE expected, got: $pair"
		key="${pair%%=*}"
		value="${pair#*=}"
		schema_known "$key" || fail 5 "unknown key: $key"
		if schema_is_secret "$key"; then
			fail 3 "$key: a secret, changed with the settings secret command"
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
	[[ ${#SETTINGS_PAIRS[@]} -ge 1 ]] || fail 2 "settings check: at least one KEY=VALUE is needed"
	staged=$(settings_stage "${SETTINGS_PAIRS[@]}") || exit $?
	changed=$(settings_changed "${SETTINGS_PAIRS[@]}")
	# shellcheck disable=SC2086
	weight=$(settings_weight $changed)
	out=$(config_validate_staged dpistack.conf "$staged")
	rc=$?
	errors="[]"
	if ((rc == 0)); then
		# The one conflict of two keys that the preflight would stop on only
		# at the end of a long apply: say it now, in the panel's own words.
		settings_load_staged "$staged"
		if [[ "${CONF[SURICATA_RUNTIME]:-native}" == "docker" && "${CONF[NDPI_ENABLE]:-no}" == "yes" ]]; then
			rc=3
			out="NDPI_ENABLE: the nDPI plugin is not in the Suricata docker image; set NDPI_ENABLE=no in the same change, or keep SURICATA_RUNTIME=native"
		fi
	fi
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
	[[ ${#pairs[@]} -ge 1 ]] || fail 2 "settings set: at least one KEY=VALUE is needed"
	local staged out rc changed weight warn
	staged=$(settings_stage "${pairs[@]}") || exit $?
	changed=$(settings_changed "${pairs[@]}")
	if [[ -z "$changed" ]]; then
		rm -f "$staged"
		echo "no changes"
		return 0
	fi
	# shellcheck disable=SC2086
	weight=$(settings_weight $changed)
	out=$(config_validate_staged dpistack.conf "$staged")
	rc=$?
	if ((rc != 0)); then
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out"
		fail 3 "settings: check failed, dpistack.conf unchanged"
	fi
	# A busy port is a stop with a way out: the holder and a free port.
	settings_load_staged "$staged"
	# shellcheck disable=SC2086
	warn=$(settings_port_warnings $changed | head -n 1)
	if [[ -n "$warn" ]]; then
		local key port who suggestion
		IFS='|' read -r key port who suggestion _ <<<"$warn"
		rm -f "$staged"
		fail 3 "port $port ($key) is already busy: $who${suggestion:+; free: $suggestion}"
	fi
	if [[ "$weight" == "heavy" && "$mode" == "apply" ]]; then
		rm -f "$staged"
		fail 3 "heavy change ($(paste -sd, <<<"$changed")): --apply-heavy is needed"
	fi
	if ((confirm)); then
		DPISTACK_ACCESS_CONFIRM=1
		export DPISTACK_ACCESS_CONFIRM
	fi
	config_commit dpistack.conf "$staged"
	rm -f "$staged"
	case "$mode" in
	commit) echo "dpistack.conf written, not applied" ;;
	apply)
		if ! ctl_cmd_reconfigure; then
			cmd_config_revert dpistack.conf >/dev/null
			fail 1 "reconfigure failed, dpistack.conf restored"
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
	active | activating) fail 3 "applying is already running" ;;
	esac
	systemctl reset-failed "$SETTINGS_UNIT.service" >/dev/null 2>&1 || true
	systemd-run --quiet --unit="$SETTINGS_UNIT" --description="dpistack: applying settings" \
		--collect "$SCRIPT_DIR/install.sh" "${args[@]}" >/dev/null ||
		fail 1 "could not start applying"
	echo "applying started: $SETTINGS_UNIT"
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
	[[ $# -eq 1 ]] || fail 2 "settings secret: KEY is needed"
	local key="$1" value tmp
	if ! schema_known "$key" || ! schema_is_secret "$key"; then
		fail 5 "$key: not a schema secret"
	fi
	IFS= read -r value || true
	if [[ -n "$value" ]]; then
		schema_validate_one "$key" "$value" >/dev/null || fail 3 "$key: the value does not fit"
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
		fail 1 "reconfigure failed, the secret is written"
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

# ------------------------------------------------------------ self-update
#
# `dpistack self-update [--check] | run | job`: the update of dpistack itself.
# Only a release of the project's own repository is ever installed: the tag
# comes from its "latest release" document, has to be newer than the running
# version, the archive is the one GitHub builds for that tag over https and
# must carry that same version in lib/common.sh. `run` starts the update as
# the transient unit below (the panel restarts in the middle of it), `job`
# shows that unit, `apply` is what the unit runs.

SELFUPDATE_UNIT="dpistack-selfupdate"
SELFUPDATE_API="https://api.github.com/repos/FlexEbat/dpistack/releases/latest"
SELFUPDATE_ARCHIVE="https://github.com/FlexEbat/dpistack/archive/refs/tags"

# selfupdate_url <default> <override-variable> - the override exists for the
# tests only: it is honoured only when DPISTACK_ROOT is set (a sandbox).
selfupdate_url() {
	local default="$1" override="${2:-}"
	if [[ -n "${DPISTACK_ROOT:-}" && -n "$override" ]]; then
		echo "$override"
	else
		echo "$default"
	fi
}

# selfupdate_latest_tag - prints v1.2.3 of the latest release or fails.
selfupdate_latest_tag() {
	local url doc tag
	url=$(selfupdate_url "$SELFUPDATE_API" "${DPISTACK_UPDATE_API:-}")
	doc=$(curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' "$url") ||
		fail 1 "could not reach the release server"
	tag=$(printf '%s' "$doc" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
	[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 1 "the latest release has no usable version tag"
	echo "$tag"
}

# selfupdate_is_newer <tag> - 0 when the tag is a higher version than the running one.
selfupdate_is_newer() {
	local v="${1#v}"
	[[ "$v" != "$DPISTACK_VERSION" ]] &&
		[[ "$(printf '%s\n%s\n' "$v" "$DPISTACK_VERSION" | sort -V | tail -n1)" == "$v" ]]
}

selfupdate_check() {
	local tag newer=false json=0
	[[ "${1:-}" == "--json" ]] && json=1
	tag=$(selfupdate_latest_tag) || exit 1
	selfupdate_is_newer "$tag" && newer=true
	if ((json)); then
		printf '{"version":"%s","latest":"%s","update_available":%s}\n' "$DPISTACK_VERSION" "${tag#v}" "$newer"
	elif [[ "$newer" == true ]]; then
		echo "dpistack $DPISTACK_VERSION is running, ${tag#v} is available: sudo dpistack self-update"
	else
		echo "dpistack $DPISTACK_VERSION is the latest version"
	fi
}

selfupdate_run() {
	local tag
	tag=$(selfupdate_latest_tag) || exit 1
	selfupdate_is_newer "$tag" || fail 3 "there is no newer release than $DPISTACK_VERSION"
	case "$(systemctl is-active "$SELFUPDATE_UNIT.service" 2>/dev/null)" in
	active | activating) fail 3 "an update is already running" ;;
	esac
	systemctl reset-failed "$SELFUPDATE_UNIT.service" >/dev/null 2>&1 || true
	systemd-run --quiet --unit="$SELFUPDATE_UNIT" --description="dpistack: updating to ${tag#v}" \
		--collect "$SCRIPT_DIR/install.sh" self-update apply >/dev/null ||
		fail 1 "could not start the update"
	echo "update to ${tag#v} started: $SELFUPDATE_UNIT"
}

selfupdate_job() {
	local state result lines
	state=$(systemctl is-active "$SELFUPDATE_UNIT.service" 2>/dev/null || true)
	[[ -n "$state" ]] || state=unknown
	result=$(systemctl show -p Result --value "$SELFUPDATE_UNIT.service" 2>/dev/null || true)
	lines=$(journalctl -u "$SELFUPDATE_UNIT.service" -n 200 --no-pager -o cat 2>/dev/null | settings_lines_json 200)
	printf '{"state":"%s","result":"%s","log":%s}\n' "$(json_escape "$state")" "$(json_escape "${result:-}")" "$lines"
}

# selfupdate_apply - download, check, then run the NEW installer on the saved
# config: it renews the persistent command, the panel and its unit, and
# restarts what changed. The config is never rewritten with defaults.
selfupdate_apply() {
	local tag url tmp src
	tag=$(selfupdate_latest_tag) || exit 1
	if ! selfupdate_is_newer "$tag"; then
		echo "dpistack $DPISTACK_VERSION is the latest version, nothing to do"
		return 0
	fi
	url=$(selfupdate_url "$SELFUPDATE_ARCHIVE/${tag}.tar.gz" "${DPISTACK_UPDATE_ARCHIVE:-}")
	tmp=$(mktemp -d) || fail 1 "no temporary directory"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp'" EXIT
	echo "downloading $tag"
	curl -fsSL --max-time 300 -o "$tmp/src.tar.gz" "$url" || fail 1 "could not download $tag"
	# Nothing outside the target directory, whatever the archive says.
	if tar -tzf "$tmp/src.tar.gz" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
		fail 1 "the archive has an unsafe path, nothing was installed"
	fi
	src="$tmp/src"
	mkdir -p "$src"
	tar -xzf "$tmp/src.tar.gz" -C "$src" --strip-components=1 --no-same-owner ||
		fail 1 "could not unpack the archive"
	[[ -f "$src/install.sh" && -f "$src/lib/common.sh" ]] || fail 1 "the archive is not a dpistack release"
	grep -q "^DPISTACK_VERSION=\"${tag#v}\"" "$src/lib/common.sh" ||
		fail 1 "the archive does not carry the version ${tag#v}, nothing was installed"
	echo "installing ${tag#v} on the saved config"
	(cd "$src" && bash ./install.sh install -y)
}

cmd_self_update() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	"" | --check) selfupdate_check ;;
	--json | check) selfupdate_check --json ;;
	run) selfupdate_run ;;
	job) selfupdate_job ;;
	apply)
		restricted_caller && fail 2 "self-update apply: not for the panel, use run"
		selfupdate_apply
		;;
	*) fail 2 "self-update: [--check] | check | run | job | apply" ;;
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
		fail 3 "$key: check failed, file unchanged"
	fi
	config_commit dpistack.conf "$staged"
	rm -f "$staged"
	if ! ctl_cmd_reconfigure; then
		cmd_config_revert dpistack.conf >/dev/null
		fail 1 "reconfigure failed, dpistack.conf restored"
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
		fail 3 "mode ips: only for SURICATA_RUNTIME=native"
	if [[ "$(conf_get IPS_METHOD nfq)" == "nfq" ]]; then
		[[ -n "$(ips_backend)" ]] || fail 3 "mode ips: neither iptables nor nft found (needed for the NFQUEUE queue)"
	fi
	command -v suricata >/dev/null 2>&1 || fail 4 "mode ips: suricata is not installed"
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
		echo "mode: $mode (method $method)"
		[[ "$pending" == "true" ]] && echo "waiting for mode-confirm: ${remaining} s until the rollback to ids"
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
			[[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail 2 "mode: --confirm-timeout needs a number of seconds"
			timeout="$2"
			shift 2
			;;
		*) fail 2 "mode: unknown argument: $1" ;;
		esac
	done
	((timeout >= MODE_TIMEOUT_MIN && timeout <= MODE_TIMEOUT_MAX)) ||
		fail 2 "mode: --confirm-timeout from $MODE_TIMEOUT_MIN to $MODE_TIMEOUT_MAX seconds"

	if [[ "$target" == "ids" ]]; then
		mode_go_ids
		echo "ids mode"
		return 0
	fi

	mode_check_ips_possible
	if [[ "$(conf_get SURICATA_MODE ids)" == "ips" && -z "$(mode_pending_deadline)" ]]; then
		echo "already in ips mode"
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
			fail 1 "mode ips: the firewall rules were not applied, the mode is back to ids"
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
		fail 1 "mode ips: could not start the rollback timer, the mode is back to ids"
	fi
	echo "ips mode enabled; confirm with the mode-confirm command within ${timeout} s, or it goes back to ids"
	mode_drop_rules_present ||
		echo "warning: there are no drop rules (neither in local.rules nor in drop.conf), IPS will only alert, like IDS"
}

cmd_mode_confirm() {
	[[ $# -eq 0 ]] || fail 2 "mode-confirm: no arguments"
	local deadline
	deadline=$(mode_pending_deadline)
	[[ -n "$deadline" ]] || fail 3 "mode-confirm: nothing to confirm (there is no switch to ips or it has already rolled back)"
	if (($(mode_now) > deadline)); then
		fail 3 "mode-confirm: the confirmation time is over, the mode is going back to ids"
	fi
	mode_cancel_timer
	rm -f "$(path_mode_pending)"
	echo "ips mode confirmed"
}

# mode-rollback runs from the timer (and at boot): an unconfirmed switch
# goes back to ids, the DPISTACK rules go away.
cmd_mode_rollback() {
	[[ -n "$(mode_pending_deadline)" ]] || return 0
	mode_go_ids
	echo "ips mode not confirmed, back to ids"
}

cmd_fw() {
	[[ $# -eq 1 ]] || fail 2 "fw: apply|remove|restore"
	case "$1" in
	apply)
		ips_fw_apply "$(conf_get IPS_NFQ_CHAINS INPUT,OUTPUT,FORWARD)" || fail 1 "fw apply: the firewall refused"
		;;
	remove) ips_fw_remove ;;
	restore)
		# Boot: an unconfirmed switch did not survive the reboot, the rest
		# is put back as the config says.
		if [[ -n "$(mode_pending_deadline)" ]]; then
			cmd_mode_rollback
		elif [[ "$(conf_get SURICATA_MODE ids)" == "ips" && "$(conf_get IPS_METHOD nfq)" == "nfq" ]]; then
			ips_fw_apply "$(conf_get IPS_NFQ_CHAINS INPUT,OUTPUT,FORWARD)" || fail 1 "fw restore: the firewall refused"
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
		[[ $# -eq 0 ]] || fail 2 "iface list: no arguments"
		printf '%s\n' "${current[@]}"
		;;
	add)
		[[ $# -eq 1 ]] || fail 2 "iface add: an interface name is needed"
		if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$ ]] || ! ip link show "$1" >/dev/null 2>&1; then
			fail 5 "the interface is not in the system: $1"
		fi
		if in_list "$1" "${current[@]}"; then
			echo "already in the list: $1"
			return 0
		fi
		current+=("$1")
		iface_set_list "$(
			IFS=,
			echo "${current[*]}"
		)"
		;;
	remove)
		[[ $# -eq 1 ]] || fail 2 "iface remove: an interface name is needed"
		in_list "$1" "${current[@]}" || fail 5 "the interface is not in IFACES: $1"
		((${#current[@]} > 1)) || fail 3 "cannot remove the last interface"
		local -a rest=() i
		for i in "${current[@]}"; do
			[[ "$i" == "$1" ]] || rest+=("$i")
		done
		iface_set_list "$(
			IFS=,
			echo "${rest[*]}"
		)"
		;;
	*) fail 2 "iface: unknown subcommand: $sub" ;;
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
	[[ $# -eq 2 ]] || fail 2 "rules-group: enable|disable <group>"
	[[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 5 "invalid group name"
	case "$1" in
	enable) rules_edit_line enable.conf add "group:$2.rules" ;;
	disable) rules_edit_line enable.conf remove "group:$2.rules" ;;
	*) fail 2 "rules-group: enable|disable" ;;
	esac
}

cmd_rules_sid() {
	[[ $# -eq 2 ]] || fail 2 "rules-sid: enable|disable <sid>"
	[[ "$2" =~ ^[0-9]+$ ]] || fail 5 "sid must be a number"
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
	command -v suricata-update >/dev/null 2>&1 || fail 4 "suricata-update is not installed"
	case "$sub" in
	list)
		if [[ $# -eq 1 && "$1" == "--enabled" ]]; then
			suricata-update list-enabled-sources -D "$data_dir"
			return
		fi
		[[ $# -eq 0 ]] || fail 2 "rules-sources list: no arguments or --enabled"
		suricata-update list-sources -D "$data_dir"
		;;
	enable | disable | remove)
		[[ $# -eq 1 ]] || fail 2 "rules-sources $sub: a source name is needed"
		# No leading "-": the name goes to suricata-update as an argument and
		# would be read as an option.
		[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail 5 "invalid source name"
		suricata-update "$sub-source" -D "$data_dir" "$1"
		;;
	add-url)
		[[ $# -eq 1 ]] || fail 2 "rules-sources add-url: a URL is needed"
		[[ "$1" =~ ^https?://[A-Za-z0-9._:/@+,=-]+$ ]] || fail 5 "invalid URL"
		suricata-update add-source -D "$data_dir" \
			"dpistack-custom-$(printf '%s' "$1" | sha256sum | cut -c1-8)" "$1"
		;;
	*) fail 2 "rules-sources: unknown subcommand: $sub" ;;
	esac
}

cmd_rules_search() {
	[[ $# -eq 1 && -n "$1" ]] || fail 2 "rules-search: exactly one query is needed"
	local ruleset
	ruleset=$(path_suricata_ruleset)
	[[ -f "$ruleset" ]] || fail 4 "no rule set"
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
	[[ $# -eq 0 ]] || fail 2 "rules-update: no arguments"
	command -v suricata-update >/dev/null 2>&1 || fail 4 "suricata-update is not installed"
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
			echo "suricata -T did not accept the new rule set" >>"$log"
			ok=0
		fi
	elif ((ok)) && command -v suricata >/dev/null 2>&1; then
		local check_dir
		check_dir=$(mktemp -d)
		if ! suricata -T -c "$(path_suricata_yaml)" -l "$check_dir" >>"$log" 2>&1; then
			echo "suricata -T did not accept the new rule set" >>"$log"
			ok=0
		fi
		rm -rf "$check_dir"
	fi
	if ((ok)); then
		suricata_reload_now >>"$log" 2>&1 || {
			echo "reloading the rules failed" >>"$log"
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
		fail 1 "rules-update failed, the previous rule set is restored"
	fi
	[[ -n "$snap" ]] && rm -f "$snap"
	return 0
}

# ------------------------------------------------------------------ test

cmd_test() {
	[[ $# -ge 1 && $# -le 2 ]] || fail 2 "test: bittorrent|https|all [--json]"
	local which="$1" json=0
	if [[ $# -eq 2 ]]; then
		[[ "$2" == "--json" ]] || fail 2 "test: unknown argument: $2"
		json=1
	fi
	local -a names
	case "$which" in
	bittorrent | https) names=("$which") ;;
	all) names=("${VERIFY_TESTS[@]}") ;;
	*) fail 5 "unknown test: $which" ;;
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
	*) fail 2 "health: unknown argument" ;;
	esac
	[[ $# -le 1 ]] || fail 2 "health: extra arguments"
	local watch="$SCRIPT_DIR/bin/dpistack-watch"
	[[ -x "$watch" ]] || fail 4 "dpistack-watch is not installed"
	"$watch" || fail 1 "health: dpistack-watch failed"
	local file
	file=$(path_health_json)
	[[ -f "$file" ]] || fail 1 "health: $file was not created"
	if ((json)); then
		cat "$file"
	else
		jq -r '"overall: \(.overall)  (\(.ts))", (.checks[] | "\(.id)\t\(.status)\t\(.value)\t\(.detail)")' "$file" || fail 1 "health: jq is needed"
	fi
}

# ----------------------------------------------------------- panel-passwd

cmd_panel_passwd() {
	[[ $# -eq 0 ]] || fail 2 "panel-passwd: the password is read from stdin"
	local pw=""
	IFS= read -r pw || true
	[[ -n "$pw" ]] || fail 2 "panel-passwd: empty password"
	command -v argon2 >/dev/null 2>&1 || fail 1 "the argon2 package is not installed"
	panel_auth_write "$pw" || fail 1 "could not write the password hash"
	echo "panel password updated"
}

# --- runtime: what can run in Docker, and the links between parts (4.10) ---

# RUNTIME_MATRIX rows: id|docker (yes|no|follows:<id>)|why. The same table is
# in tech.md 4.10 and docs/runtimes.md; tests/runtime_matrix.bats compares the
# ids with COMPONENTS and the docker keys with the schema.
RUNTIME_MATRIX=(
	"suricata|yes|image jasonish/suricata; no nDPI plugin in the image and no IPS (mode ips needs a native Suricata)"
	"ndpi|no|the plugin is built into a native Suricata, there is no image for it"
	"rules|follows:suricata|suricata-update runs on the host or inside the Suricata container, whichever Suricata runs in"
	"evebox|yes|image jasonish/evebox"
	"redis|follows:ntopng|the store behind ntopng, always in the same runtime as ntopng"
	"ntopng|yes|image ntop/ntopng"
	"victoriametrics|yes|image victoriametrics/victoria-metrics, only when it is the selected backend"
	"prometheus|yes|image prom/prometheus, only when it is the selected backend"
	"node_exporter|yes|image prom/node-exporter"
	"grafana|yes|image grafana/grafana-oss"
	"panel|yes|an image built on the host from the panel binary; it runs privileged with pid host and reaches dpistack through nsenter"
	"watch|no|a systemd timer that calls the dpistack of the host"
	"nginx|no|a package of the host, used only with ACCESS_MODE=nginx"
	"firewall|no|rules of the host kernel (iptables, nft, ufw, firewalld), they also guard the containers that use the host network"
	"installer|no|install.sh and the dpistack command are scripts of the host"
)

# runtime_tcp <host> <port> - something accepts a connection.
runtime_tcp() {
	# shellcheck disable=SC2016  # $1 and $2 belong to the inner shell
	timeout 2 bash -c ': </dev/tcp/$1/$2' _ "$1" "$2" 2>/dev/null
}

# runtime_state <id> - the state word of a component, absent when it is not
# listed.
runtime_state() {
	component_listed "$1" || {
		echo absent
		return
	}
	component_state "$(component_unit "$1")"
}

# runtime_link <from> <to> <what> <endpoint> <kind> - one link as JSON. ok is
# true or false when both ends run, null when one of them does not (nothing to
# check yet).
runtime_link() {
	local from="$1" to="$2" what="$3" endpoint="$4" kind="$5" ok=null
	local sf st
	sf=$(runtime_state "$from")
	st=$(runtime_state "$to")
	if [[ "$sf" == active && "$st" == active ]]; then
		case "$kind" in
		tcp)
			if runtime_tcp "${endpoint%:*}" "${endpoint##*:}"; then ok=true; else ok=false; fi
			;;
		file)
			if [[ -r "$endpoint" ]]; then ok=true; else ok=false; fi
			;;
		esac
	fi
	printf '{"from":"%s","to":"%s","what":"%s","endpoint":"%s","ok":%s}' \
		"$from" "$to" "$what" "$(json_escape "$endpoint")" "$ok"
}

runtime_links() {
	local first=1
	emit() {
		((first)) || printf ','
		first=0
		runtime_link "$@"
	}
	local host backend
	host=$(conf_get BIND_ADDR 127.0.0.1)
	[[ -z "$host" || "$host" == "0.0.0.0" ]] && host=127.0.0.1
	printf '['
	emit suricata evebox "eve.json" "$(path_suricata_eve_json)" file
	[[ "$(conf_get EVE_FILE yes)" == "yes" ]] && emit suricata panel "eve.json" "$(path_suricata_eve_json)" file
	emit redis ntopng "redis" "127.0.0.1:6379" tcp
	backend=$(conf_get METRICS_BACKEND none)
	if [[ "$backend" != none ]]; then
		local bport pport
		bport=$(conf_get METRICS_BACKEND_PORT "")
		[[ -n "$bport" ]] || { [[ "$backend" == victoriametrics ]] && bport=8428 || bport=9090; }
		pport=$(conf_get PANEL_PORT 9800)
		[[ "$(conf_get ACCESS_MODE localhost)" == nginx ]] && pport=$((pport + 10000))
		emit panel "$backend" "metrics scrape" "$host:$pport" tcp
		emit node_exporter "$backend" "metrics scrape" "$host:$(conf_get NODE_EXPORTER_PORT 9100)" tcp
		emit "$backend" grafana "data source" "$host:$bport" tcp
	fi
	printf ']'
}

cmd_runtime() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "runtime: unknown argument" ;;
	esac
	[[ $# -le 1 ]] || fail 2 "runtime: extra arguments"

	local row id docker why current first=1 mixed natives=0 dockers=0
	local out=""
	for row in "${RUNTIME_MATRIX[@]}"; do
		IFS='|' read -r id docker why <<<"$row"
		current=native
		if in_list "$id" "${COMPONENTS[@]}" && [[ "$id" != watch && "$id" != rules ]]; then
			component_listed "$id" || continue
			current=$(component_runtime "$id")
		elif [[ "$id" == rules ]]; then
			current=$(component_runtime suricata)
		fi
		if [[ "$id" =~ ^(suricata|evebox|ntopng|redis|victoriametrics|prometheus|node_exporter|grafana|panel)$ ]]; then
			[[ "$current" == docker ]] && dockers=$((dockers + 1)) || natives=$((natives + 1))
		fi
		if ((json)); then
			((first)) || out+=","
			first=0
			out+=$(printf '{"id":"%s","docker":"%s","runtime":"%s","why":"%s"}' "$id" "$docker" "$current" "$(json_escape "$why")")
		else
			out+=$(printf '%-16s docker=%-16s now=%-7s %s' "$id" "$docker" "$current" "$why")$'\n'
		fi
	done
	((dockers > 0 && natives > 0)) && mixed=true || mixed=false
	if ((json)); then
		printf '{"components":[%s],"mixed":%s,"links":%s}\n' "$out" "$mixed" "$(runtime_links)"
	else
		printf '%s' "$out"
		echo "mixed: $mixed (containers use the host network, so every part reaches the others on the host addresses)"
		runtime_links | jq -r '.[] | "link \(.from) -> \(.to) (\(.what), \(.endpoint)): \(.ok // "not checked")"'
	fi
}

# --- users, roles and permissions (4.5, 4.8; slice 34) ---

USERS_PERMS=(view events.ack tests.run components.control rules.edit settings.edit configs.edit ips.manage backup.manage update.manage audit.view users.manage)
USERS_ROLES=(viewer analyst operator admin custom)

# users_presets - the permissions of every role as one JSON object. The panel
# keeps the same table in panel/internal/auth/users.go; tests/users.bats and
# the Go tests compare the two.
users_presets() {
	local all
	all=$(printf '%s\n' "${USERS_PERMS[@]}" | jq -R . | jq -sc .)
	jq -nc --argjson all "$all" '{
		viewer: ["view"],
		analyst: ["view","events.ack","tests.run","audit.view"],
		operator: ["view","events.ack","tests.run","audit.view","components.control","rules.edit"],
		admin: $all}'
}

# users_store - writes users.json from stdin: 0640, root:dpistack.
users_store() {
	atomic_write "$(path_users)" 0640 || return 1
	if getent group dpistack >/dev/null 2>&1; then
		chown root:dpistack "$(path_users)" || return 1
	fi
}

# users_ensure - an upgrade from the one-password panel: users.json is made
# from panel.auth, the only user is admin.
users_ensure() {
	[[ -f "$(path_users)" ]] && return 0
	local hash=""
	[[ -r "$(path_panel_auth)" ]] && hash=$(head -n 1 "$(path_panel_auth)")
	[[ -n "$hash" ]] || return 0
	jq -n --arg h "$hash" --arg t "$(date -u +%FT%TZ)" \
		'{users:[{name:"admin",role:"admin",hash:$h,created:$t,disabled:false}]}' | users_store
}

users_load() {
	users_ensure || return 1
	if [[ -f "$(path_users)" ]]; then cat "$(path_users)"; else echo '{"users":[]}'; fi
}

# users_set_admin_hash <phc> - panel-passwd and the installer: the admin of
# users.json gets the hash, and is made when it is not there.
users_set_admin_hash() {
	local hash="$1" cur
	cur=$(users_load) || return 1
	jq --arg h "$hash" --arg t "$(date -u +%FT%TZ)" '
		if any(.users[]; .name=="admin") then .users |= map(if .name=="admin" then .hash=$h else . end)
		else .users += [{name:"admin",role:"admin",hash:$h,created:$t,disabled:false}] end' <<<"$cur" | users_store
}

users_check_name() {
	[[ "$1" =~ ^[a-z][a-z0-9_.-]{1,31}$ ]] || fail 2 "users: a name is 2 to 32 characters: a letter first, then letters, digits, . _ -"
}

users_check_role() {
	in_list "$1" "${USERS_ROLES[@]}" || fail 2 "users: the role is one of: ${USERS_ROLES[*]}"
}

# users_perms_json <comma list> - validated permissions as a JSON array.
users_perms_json() {
	local list="$1" p
	[[ -n "$list" ]] || fail 2 "users: --perms needs at least one permission"
	local -a items
	IFS=',' read -r -a items <<<"$list"
	for p in "${items[@]}"; do
		in_list "$p" "${USERS_PERMS[@]}" || fail 2 "users: unknown permission: $p (known: ${USERS_PERMS[*]})"
	done
	printf '%s\n' "${items[@]}" | jq -R . | jq -sc 'unique'
}

# users_commit <json> - refuses a result that leaves nobody able to manage
# users, then writes it.
users_commit() {
	local json="$1" left
	left=$(jq --argjson pre "$(users_presets)" '[.users[] | select(.disabled != true)
		| (if .role=="custom" then (.perms // []) else $pre[.role] end) | select(index("users.manage"))] | length' <<<"$json")
	((left >= 1)) || fail 3 "users: the last user who may manage users cannot be removed, disabled or demoted"
	users_store <<<"$json" || fail 1 "users: could not write users.json"
}

users_read_password() {
	local pw=""
	IFS= read -r pw || true
	[[ ${#pw} -ge 8 ]] || fail 2 "users: the password (stdin) must have at least 8 characters"
	[[ "$pw" != *$'\r'* ]] || fail 2 "users: bad password"
	printf '%s' "$pw"
}

users_hash_of() {
	command -v argon2 >/dev/null 2>&1 || fail 1 "the argon2 package is not installed"
	panel_hash "$1" || fail 1 "users: could not hash the password"
}

users_exists() {
	jq -e --arg n "$2" 'any(.users[]; .name==$n)' <<<"$1" >/dev/null
}

cmd_users() {
	local sub="${1:-}"
	[[ $# -gt 0 ]] && shift
	local cur
	case "$sub" in
	list)
		local json=0
		case "${1:-}" in
		"") ;;
		--json) json=1 ;;
		*) fail 2 "users list: unknown argument" ;;
		esac
		cur=$(users_load) || fail 1 "users: could not read users.json"
		if ((json)); then
			jq -c --argjson pre "$(users_presets)" '{users:[.users[] | {name,role,disabled:(.disabled==true),created,
				perms:(if .role=="custom" then (.perms // []) else $pre[.role] end)}]}' <<<"$cur"
		else
			jq -r --argjson pre "$(users_presets)" '.users[] | "\(.name)\t\(.role)\t\(if .disabled==true then "disabled" else "enabled" end)\t\((if .role=="custom" then (.perms // []) else $pre[.role] end) | join(","))"' <<<"$cur"
		fi
		;;
	add)
		local name="${1:-}" role="${2:-}" perms="[]"
		[[ $# -ge 2 ]] || fail 2 "users add <name> <role> [--perms a,b]: the password is read from stdin"
		shift 2
		users_check_name "$name"
		users_check_role "$role"
		if [[ "${1:-}" == "--perms" ]]; then
			[[ "$role" == custom ]] || fail 2 "users: --perms goes with the role custom"
			perms=$(users_perms_json "${2:-}") || exit $?
			shift 2
		elif [[ "$role" == custom ]]; then
			fail 2 "users: the role custom needs --perms"
		fi
		[[ $# -eq 0 ]] || fail 2 "users add: extra arguments"
		cur=$(users_load) || fail 1 "users: could not read users.json"
		users_exists "$cur" "$name" && fail 3 "users: $name exists"
		local pw hash
		pw=$(users_read_password) || exit $?
		hash=$(users_hash_of "$pw") || exit $?
		users_commit "$(jq --arg n "$name" --arg r "$role" --argjson p "$perms" --arg h "$hash" --arg t "$(date -u +%FT%TZ)" \
			'.users += [({name:$n,role:$r,hash:$h,created:$t,disabled:false} + (if $r=="custom" then {perms:$p} else {} end))]' <<<"$cur")"
		echo "user $name added"
		;;
	passwd)
		local name="${1:-}"
		[[ $# -eq 1 ]] || fail 2 "users passwd <name>: the password is read from stdin"
		users_check_name "$name"
		cur=$(users_load) || fail 1 "users: could not read users.json"
		users_exists "$cur" "$name" || fail 4 "users: no user $name"
		local pw hash
		pw=$(users_read_password) || exit $?
		hash=$(users_hash_of "$pw") || exit $?
		users_commit "$(jq --arg n "$name" --arg h "$hash" '.users |= map(if .name==$n then .hash=$h else . end)' <<<"$cur")"
		# panel.auth is the password of admin for the old paths that read it.
		[[ "$name" == admin ]] && { printf '%s\n' "$hash" | atomic_write "$(path_panel_auth)" 0640 || true; }
		echo "password of $name updated"
		;;
	role)
		local name="${1:-}" role="${2:-}" perms="[]"
		[[ $# -ge 2 ]] || fail 2 "users role <name> <role> [--perms a,b]"
		shift 2
		users_check_name "$name"
		users_check_role "$role"
		if [[ "${1:-}" == "--perms" ]]; then
			[[ "$role" == custom ]] || fail 2 "users: --perms goes with the role custom"
			perms=$(users_perms_json "${2:-}") || exit $?
			shift 2
		elif [[ "$role" == custom ]]; then
			fail 2 "users: the role custom needs --perms"
		fi
		[[ $# -eq 0 ]] || fail 2 "users role: extra arguments"
		cur=$(users_load) || fail 1 "users: could not read users.json"
		users_exists "$cur" "$name" || fail 4 "users: no user $name"
		users_commit "$(jq --arg n "$name" --arg r "$role" --argjson p "$perms" \
			'.users |= map(if .name==$n then (.role=$r | (if $r=="custom" then .perms=$p else del(.perms) end)) else . end)' <<<"$cur")"
		echo "role of $name is $role"
		;;
	disable | enable | remove)
		local name="${1:-}"
		[[ $# -eq 1 ]] || fail 2 "users $sub <name>"
		users_check_name "$name"
		cur=$(users_load) || fail 1 "users: could not read users.json"
		users_exists "$cur" "$name" || fail 4 "users: no user $name"
		case "$sub" in
		disable) users_commit "$(jq --arg n "$name" '.users |= map(if .name==$n then .disabled=true else . end)' <<<"$cur")" ;;
		enable) users_commit "$(jq --arg n "$name" '.users |= map(if .name==$n then .disabled=false else . end)' <<<"$cur")" ;;
		remove) users_commit "$(jq --arg n "$name" '.users |= map(select(.name != $n))' <<<"$cur")" ;;
		esac
		echo "user $name: $sub done"
		;;
	*) fail 2 "users: list | add | passwd | role | disable | enable | remove" ;;
	esac
}

ctl_main() {
	if [[ $# -eq 0 ]]; then
		ctl_usage
		exit 2
	fi

	# Every argument is checked before any command runs (4.5).
	local arg
	for arg in "$@"; do
		[[ "$arg" =~ ^[A-Za-z0-9._:=/@+,\ -]*$ ]] || fail 5 "invalid characters in the argument"
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
	self-update) cmd_self_update "$@" ;;
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
	runtime) cmd_runtime "$@" ;;
	users) cmd_users "$@" ;;
	version) echo "$DPISTACK_VERSION" ;;
	*)
		ctl_usage >&2
		exit 2
		;;
	esac
}
