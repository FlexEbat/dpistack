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
# shellcheck source=lib/runtime_native.sh
source "$LIB_DIR/runtime_native.sh"
# shellcheck source=lib/runtime_docker.sh
source "$LIB_DIR/runtime_docker.sh"

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
NO_COLOR=0
COMMAND=""

usage() {
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
			# shellcheck disable=SC2034 # consumed by lib/menu.sh's slice
			NO_COLOR=1
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

maybe_ask_questions() {
	if [[ "$NON_INTERACTIVE" == "1" ]]; then
		return 0
	fi
	if ! have_input_source; then
		die 2 "нет терминала для вопросов, используйте -y или DPISTACK_INPUT"
	fi
	config_ask_basic "$([[ "$ADVANCED" == "1" ]] && echo yes || echo no)"
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
		if ! "step_${name}_check"; then
			die 1 "шаг $name не прошёл проверку после применения"
		fi
		state_set_step_done "$name"
		echo "[$i/$total] $name ... готово"
	done
}

cmd_install() {
	validate_step_names "$ONLY_STEPS" "--only"
	validate_step_names "$SKIP_STEPS" "--skip"
	lock_acquire
	os_detect

	layer_config_common
	maybe_ask_questions
	config_generate_metrics_token_if_needed
	validate_or_die

	echo "Итоговый конфиг:"
	config_print_summary

	if [[ "$DRY_RUN" != "1" ]]; then
		config_write_conf "$(path_conf)"
		config_write_secrets "$(path_secrets)"
	fi

	step_preflight_check || true

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
	maybe_ask_questions
	config_generate_metrics_token_if_needed
	validate_or_die

	config_diff_and_steps "$(path_conf)"

	if [[ "$CONFIG_CHANGE_WEIGHT" == "none" ]]; then
		return 0
	fi

	if [[ "$DRY_RUN" == "1" ]]; then
		return 0
	fi

	if [[ "$CONFIG_CHANGE_WEIGHT" == "heavy" && "$NON_INTERACTIVE" == "1" && "$FORCE" != "1" ]]; then
		die 3 "тяжёлые изменения в неинтерактивном режиме требуют --force"
	fi

	config_write_conf "$(path_conf)"
	config_write_secrets "$(path_secrets)"
	echo "конфиг применён"
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
	status)
		cmd_status
		;;
	upgrade | uninstall)
		echo "$COMMAND: пока не поддерживается" >&2
		exit 2
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
