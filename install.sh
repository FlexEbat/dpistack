#!/usr/bin/env bash
# Entry point for both the pre-install invocation (install.sh) and,
# once selfinstall has run, the persistent `dpistack` command
# (tech.md 4.4, 5.1, 5.2). Slice 1 wires the CLI, config layering and
# an all-stub step pipeline; components fill in their steps later.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/paths.sh
source "$LIB_DIR/paths.sh"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/os.sh
source "$LIB_DIR/os.sh"
# shellcheck source=lib/state.sh
source "$LIB_DIR/state.sh"
# shellcheck source=lib/schema.sh
source "$LIB_DIR/schema.sh"
# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=lib/render.sh
source "$LIB_DIR/render.sh"
# shellcheck source=lib/menu.sh
source "$LIB_DIR/menu.sh"

STEPS_ORDER=(preflight selfinstall ndpi suricata rules redis ntopng evebox metrics access panel watch verify)
for _step in "${STEPS_ORDER[@]}"; do
	# shellcheck disable=SC1090
	source "$LIB_DIR/step_${_step}.sh"
done
unset _step

BIN_NAME=$(basename -- "$0")

NON_INTERACTIVE=0
ADVANCED=0
DRY_RUN=0
CONFIG_FILE=""
SET_ARGS=()
ONLY_STEPS=""
SKIP_STEPS=""
FORCE=0
PURGE=0
CLI_NO_COLOR=0
COMMAND=""

usage() {
	echo "dpistack v${DPISTACK_VERSION}"
	cat <<'EOF'
Использование: install.sh <команда> [опции]

команды:  install | reconfigure | upgrade | uninstall | status | test | logs
опции:
  --config FILE          путь к dpistack.conf (по умолчанию /etc/dpistack/dpistack.conf)
  --set KEY=VALUE        переопределить ключ, можно повторять
  --non-interactive, -y  без вопросов; недостающее берётся из умолчаний
  --advanced             спрашивать все ключи, а не только уровень basic
  --dry-run              показать план, ничего не менять
  --only STEP[,STEP]     выполнить только указанные шаги
  --skip STEP[,STEP]     пропустить шаги
  --force                перезаписать вручную изменённые файлы (с бэкапом)
  --purge                для uninstall: удалить также данные и конфиги
  --no-color             без ANSI-цветов в меню и выводе
EOF
}

parse_args() {
	if [[ $# -eq 0 ]]; then
		usage
		exit 2
	fi
	COMMAND="$1"
	shift
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--config)
			CONFIG_FILE="${2:-}"
			shift 2
			;;
		--set)
			SET_ARGS+=("${2:-}")
			shift 2
			;;
		--non-interactive | -y)
			NON_INTERACTIVE=1
			shift
			;;
		--advanced)
			ADVANCED=1
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--only)
			ONLY_STEPS="${2:-}"
			shift 2
			;;
		--skip)
			SKIP_STEPS="${2:-}"
			shift 2
			;;
		--force)
			FORCE=1
			shift
			;;
		--purge)
			# shellcheck disable=SC2034 # consumed by uninstall's slice
			PURGE=1
			shift
			;;
		--no-color)
			CLI_NO_COLOR=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "неизвестная опция: $1" >&2
			usage
			exit 2
			;;
		esac
	done
}

step_selected() {
	# step_selected <name> -> 0 if it should run given --only/--skip
	local name="$1"
	if [[ -n "$ONLY_STEPS" ]]; then
		[[ ",$ONLY_STEPS," == *",$name,"* ]] && return 0
		return 1
	fi
	if [[ -n "$SKIP_STEPS" ]]; then
		[[ ",$SKIP_STEPS," == *",$name,"* ]] && return 1
	fi
	return 0
}

validate_step_names() {
	local list="$1" label="$2"
	[[ -z "$list" ]] && return 0
	local name
	local IFS=','
	for name in $list; do
		local known=0
		local s
		for s in "${STEPS_ORDER[@]}"; do
			[[ "$s" == "$name" ]] && known=1
		done
		if [[ "$known" -ne 1 ]]; then
			die 2 "$label: неизвестный шаг $name"
		fi
	done
}

have_input_source() {
	[[ -n "${DPISTACK_INPUT:-}" ]] && return 0
	[[ -t 0 ]] && return 0
	return 1
}

layer_config_common() {
	config_reset
	config_load_defaults
	config_load_kv_file "$(path_conf)"
	config_load_kv_file "$(path_secrets)"
	config_apply_env_secrets
	[[ -n "$CONFIG_FILE" ]] && config_load_kv_file "$CONFIG_FILE"
	local kv
	for kv in "${SET_ARGS[@]}"; do
		config_apply_set "$kv" || die 2 "$(config_apply_set "$kv")"
	done
}

maybe_run_install_menu() {
	if [[ "$NON_INTERACTIVE" == "1" ]]; then
		return 0
	fi
	if ! have_input_source; then
		die 2 "нет терминала для меню, используйте -y или DPISTACK_INPUT"
	fi
	MENU_SHOW_ADVANCED=$([[ "$ADVANCED" == "1" ]] && echo 1 || echo 0)
	menu_run_install
}

maybe_run_reconfigure_menu() {
	if [[ "$NON_INTERACTIVE" == "1" ]]; then
		return 0
	fi
	if ! have_input_source; then
		die 2 "нет терминала для меню, используйте -y или DPISTACK_INPUT"
	fi
	MENU_SHOW_ADVANCED=$([[ "$ADVANCED" == "1" ]] && echo 1 || echo 0)
	menu_run_reconfigure
}

validate_or_die() {
	local out rc
	out=$(config_validate)
	rc=$?
	if [[ "$rc" -ne 0 ]]; then
		echo "Конфиг не прошёл проверку:" >&2
		echo "$out" >&2
		exit 2
	fi
}

run_plan() {
	local total=${#STEPS_ORDER[@]}
	local i=0
	local any_pending=0
	for name in "${STEPS_ORDER[@]}"; do
		i=$((i + 1))
		step_selected "$name" || continue
		if "step_${name}_check"; then
			echo "[$i/$total] $name ... без изменений"
		else
			any_pending=1
			echo "[$i/$total] $name ... нужно применить"
			"step_${name}_plan" | sed 's/^/    /'
		fi
	done
	return "$any_pending"
}

run_apply() {
	local total=${#STEPS_ORDER[@]}
	local i=0
	for name in "${STEPS_ORDER[@]}"; do
		i=$((i + 1))
		step_selected "$name" || continue
		if "step_${name}_check"; then
			continue
		fi
		if ! "step_${name}_apply"; then
			die 1 "шаг $name упал, продолжить: install.sh install --only $name"
		fi
		if "step_${name}_check"; then
			state_set_step_done "$name"
			echo "[$i/$total] $name ... готово"
		else
			# A step can legitimately still report drift after a clean
			# apply (5.4: a manually edited file is left alone with a
			# notice, not overwritten) - that isn't a failed apply.
			echo "[$i/$total] $name ... применено частично, см. заметки выше"
		fi
	done
}

cmd_install() {
	validate_step_names "$ONLY_STEPS" "--only"
	validate_step_names "$SKIP_STEPS" "--skip"
	lock_acquire
	os_detect

	layer_config_common
	maybe_run_install_menu
	panel_password_apply
	config_generate_metrics_token_if_needed
	validate_or_die

	echo "Итоговый конфиг:"
	config_print_summary
	if [[ "$METRICS_TOKEN_JUST_GENERATED" == "1" ]]; then
		echo "Создан METRICS_TOKEN (сохраните — больше нигде не показывается и не восстанавливается): ${SECRETS[METRICS_TOKEN]}"
	fi

	if [[ "$DRY_RUN" != "1" ]]; then
		config_write_conf "$(path_conf)"
		config_write_secrets "$(path_secrets)"
	fi

	if ! step_preflight_check; then
		exit 3
	fi

	run_plan
	local pending=$?

	if [[ "$DRY_RUN" == "1" ]]; then
		echo "dry-run: план показан, конфиг не записан"
		return 0
	fi

	if [[ "$pending" -ne 0 ]]; then
		run_apply
	fi
	echo "установка завершена"
	return 0
}

cmd_reconfigure() {
	validate_step_names "$ONLY_STEPS" "--only"
	validate_step_names "$SKIP_STEPS" "--skip"
	lock_acquire
	os_detect

	if [[ ! -f "$(path_conf)" ]]; then
		die 2 "конфиг не найден, сначала выполните: install.sh install"
	fi

	layer_config_common
	maybe_run_reconfigure_menu
	config_generate_metrics_token_if_needed
	validate_or_die

	config_diff_and_steps "$(path_conf)"

	if [[ "$CONFIG_CHANGE_WEIGHT" == "none" ]]; then
		echo "изменений нет"
		return 0
	fi

	if [[ "$DRY_RUN" == "1" ]]; then
		return 0
	fi

	# The interactive menu (lib/menu.sh) already ran this exact
	# confirmation and suricata -T check from inside its own input loop
	# before returning - redoing it here would both duplicate the
	# prompt and reread DPISTACK_INPUT from byte 0 (the menu's fd 8 is
	# already closed by now), landing on the wrong line.
	if [[ "$MENU_ALREADY_CONFIRMED" != "1" ]]; then
		if [[ "$CONFIG_CHANGE_WEIGHT" == "heavy" ]]; then
			if [[ "$NON_INTERACTIVE" == "1" ]]; then
				if [[ "$FORCE" != "1" ]]; then
					die 3 "тяжёлые изменения в неинтерактивном режиме требуют --force"
				fi
			else
				die 3 "тяжёлые изменения требуют подтверждения, нет терминала для вопроса"
			fi
		fi

		# criterion 4 (slice 8): validate the new suricata.yaml with a
		# real `suricata -T` before touching anything on disk, so a
		# failed check leaves the old suricata.yaml and dpistack.conf
		# alone. (Non-interactive -y path only now; see above.)
		local step
		for step in "${CONFIG_AFFECTED_STEPS[@]}"; do
			if [[ "$step" == "suricata" ]]; then
				if ! suricata_validate_render "$(suricata_render_yaml)"; then
					die 1 "suricata -T упал на новом suricata.yaml, изменения не применены (см. вывод выше)"
				fi
			fi
		done
	fi

	panel_password_apply
	config_write_conf "$(path_conf)"
	config_write_secrets "$(path_secrets)"

	for step in "${CONFIG_AFFECTED_STEPS[@]}"; do
		step_selected "$step" || continue
		if ! "step_${step}_apply"; then
			die 1 "шаг $step упал при reconfigure"
		fi
	done

	echo "конфиг применён"
	return 0
}

cmd_upgrade() {
	lock_acquire
	os_detect
	if [[ ! -f "$(path_conf)" ]]; then
		die 2 "конфиг не найден, сначала выполните: install.sh install"
	fi
	layer_config_common

	local -a packages=()
	case "${CONF[SURICATA_SOURCE]:-}" in
	distro | oisf) packages+=("$SURICATA_PACKAGE") ;;
	esac
	command -v redis-server >/dev/null 2>&1 && packages+=("$REDIS_PACKAGE")
	command -v ntopng >/dev/null 2>&1 && packages+=("$NTOPNG_PACKAGE")
	command -v evebox >/dev/null 2>&1 && packages+=("$EVEBOX_PACKAGE")

	if [[ "${#packages[@]}" -eq 0 ]]; then
		echo "нечего обновлять"
		return 0
	fi

	if [[ "${CONF[PIN_VERSIONS]:-no}" == "yes" ]]; then
		echo "upgrade: PIN_VERSIONS=yes - apt сам пропустит закреплённые пакеты (apt-mark hold): ${packages[*]}"
	fi
	run apt-get install --only-upgrade -y "${packages[@]}"
	return 0
}

# uninstall removes only what dpistack itself created (its own units,
# its own rendered nginx snippet, its own conf/state). It never stops,
# disables, or removes the underlying Suricata/Redis/ntopng/EveBox
# packages or services - "оставляет данные и конфиги" (5.7) reads most
# safely as "leave the working stack alone", not as "tear down a
# production IDS because its manager was uninstalled". --purge extends
# this to those components' own rendered configs/data, but still never
# touches packages (5.7's exemption for pre-existing packages is hard
# to honour precisely without real install-provenance tracking, so the
# conservative reading - never remove packages at all - was chosen).
cmd_uninstall() {
	lock_acquire
	os_detect

	if [[ ! -f "$(path_conf)" ]]; then
		echo "нечего удалять"
		return 0
	fi

	layer_config_common

	run systemctl disable --now "$RULES_TIMER" 2>/dev/null || true
	rm -f "$(path_rules_timer_unit)" "$(path_rules_service_unit)"
	run systemctl daemon-reload

	if [[ "${CONF[SURICATA_SOURCE]:-}" == "source" ]]; then
		run systemctl disable --now "$SURICATA_UNIT" 2>/dev/null || true
		rm -f "$(path_suricata_service_unit)"
		run systemctl daemon-reload
	fi

	if [[ "${CONF[ACCESS_MODE]:-}" == "nginx" && "${CONF[NGINX_MANAGE]:-}" == "yes" ]]; then
		rm -f "$(path_nginx_confd)"
		run systemctl reload "$NGINX_UNIT" 2>/dev/null || true
	fi
	rm -f "$(path_nginx_snippet)"

	if [[ "$PURGE" == "1" ]]; then
		rm -f "$(path_suricata_yaml)" "$(path_suricata_logrotate)" \
			"$(path_suricata_enable_conf)" "$(path_suricata_disable_conf)" \
			"$(path_suricata_modify_conf)" "$(path_suricata_drop_conf)"
		rm -rf "$(dirname "$(path_suricata_ruleset)")"
		rm -f "$(path_ntopng_conf)" "$(path_evebox_yaml)"
		rm -rf "$(access_tls_dir)" 2>/dev/null || true
		echo "uninstall --purge: конфиги и данные компонентов удалены (пакеты не трогал)"
	fi

	rm -f "$(path_conf)" "$(path_conf_draft)" "$(path_secrets)"
	rm -rf "$(path_state_dir)"

	echo "готово"
	return 0
}

cmd_status() {
	os_detect
	layer_config_common
	local name
	for name in "${STEPS_ORDER[@]}"; do
		if "step_${name}_check"; then
			echo "$name: в порядке"
		else
			echo "$name: расхождение"
		fi
	done
}

main() {
	parse_args "$@"
	case "$COMMAND" in
	install)
		cmd_install
		;;
	reconfigure)
		cmd_reconfigure
		;;
	upgrade)
		cmd_upgrade
		;;
	uninstall)
		cmd_uninstall
		;;
	status)
		cmd_status
		;;
	test | logs)
		echo "$COMMAND доступна только через dpistack после установки, не через $BIN_NAME" >&2
		exit 2
		;;
	*)
		echo "неизвестная команда: $COMMAND" >&2
		usage
		exit 2
		;;
	esac
}

main "$@"
