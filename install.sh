#!/usr/bin/env bash
# Entry point for both the pre-install invocation (install.sh) and,
# once selfinstall has run, the persistent `dpistack` command
# (tech.md 4.4, 5.1, 5.2). Slice 1 wires the CLI, config layering and
# an all-stub step pipeline; components fill in their steps later.
set -uo pipefail

# readlink -f: `dpistack` is a symlink to the installed install.sh.
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" &>/dev/null && pwd)
LIB_DIR="$SCRIPT_DIR/lib"
# Where things that do not travel inside the installer lie: the panel
# source or a prebuilt binary. Next to install.sh unless dpistack-install.sh
# (one file, unpacked elsewhere) says otherwise.
# shellcheck disable=SC2034 # read by lib/step_panel.sh and step_preflight.sh
ORIGIN_DIR="${DPISTACK_ORIGIN_DIR:-$SCRIPT_DIR}"

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
# shellcheck source=lib/runtime_docker.sh
source "$LIB_DIR/runtime_docker.sh"
# shellcheck source=lib/ips.sh
source "$LIB_DIR/ips.sh"

STEPS_ORDER=(preflight selfinstall ndpi suricata rules redis ntopng evebox metrics nodeexp grafana access panel watch verify)
for _step in "${STEPS_ORDER[@]}"; do
	# shellcheck disable=SC1090
	source "$LIB_DIR/step_${_step}.sh"
done
unset _step

# step_call <check|apply|plan> <step> [args] - runs a step function; the
# steps of a switched-off component report "no changes" and do nothing.
step_call() {
	local fn="$1" name="$2"
	shift 2
	if ! step_component_enabled "$name"; then
		[[ "$fn" == "plan" ]] && echo "${name}: switched off by its *_ENABLE key, skipped"
		return 0
	fi
	"step_${name}_${fn}" "$@"
}
# shellcheck source=lib/ctl.sh
source "$LIB_DIR/ctl.sh"

BIN_NAME="$(basename -- "$0")"
# Test hook: every argument is a verb. Not inherited by the installer that
# `reconfigure` starts.
VERBS_ONLY="${DPISTACK_VERBS_ONLY:-0}"
unset DPISTACK_VERBS_ONLY

NON_INTERACTIVE=0
ADVANCED=0
FAST=0
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
Usage: install.sh [command] [options]
       install.sh             (no command, on a terminal) opens the install menu
       install.sh --fast      the short questions first (interfaces, Suricata source, access, metrics, panel)

setup:      install | reconfigure | upgrade | uninstall | diag
control:    status [--json] | start|stop|restart <id> | reload suricata | logs <id> | test | health |
            settings | config-read|config-write|config-revert | rules-* | iface | mode | fw |
            panel-passwd | version   (full list: dpistack help)
dpistack without a command opens the menu: install if there is no config, control otherwise.
Runs as root only (sudo dpistack ...).
options:
  --config FILE          path to dpistack.conf (default /etc/dpistack/dpistack.conf)
  --set KEY=VALUE        override a key, may be repeated
  --non-interactive, -y  no questions; missing values take their defaults
  --fast                 install: the short questionnaire instead of the guided setup that asks every setting
  --advanced             ask every key, not only the basic level
  --dry-run              show the plan, change nothing
  --only STEP[,STEP]     run only the given steps
  --skip STEP[,STEP]     skip steps
  --force                overwrite hand-edited files (with a backup)
  --purge                for uninstall: also remove data and configs
  --no-color             no ANSI colors in the menu and output

diag collects a report for troubleshooting (platform, versions, repositories, config without secrets,
services, logs) to stdout and to the DIAG_OUT file (by default a new temporary file, its path is printed).
EOF
}

# require_value <option> <argument count left> - an option that takes a value
# and got none: `shift 2` would not move and the loop would spin forever.
require_value() {
	if (($2 < 2)); then
		echo "option $1 needs a value" >&2
		usage
		exit 2
	fi
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
			require_value "$1" "$#"
			CONFIG_FILE="${2:-}"
			shift 2
			;;
		--set)
			require_value "$1" "$#"
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
		--fast)
			FAST=1
			shift
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		--only)
			require_value "$1" "$#"
			ONLY_STEPS="${2:-}"
			shift 2
			;;
		--skip)
			require_value "$1" "$#"
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
			echo "unknown option: $1" >&2
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
			die 2 "$label: unknown step $name"
		fi
	done
}

# have_input_source - the menu has somewhere to read from: DPISTACK_INPUT, a
# terminal on stdin, or (a run fed through a pipe: stdin is the script) the terminal device
# itself. DPISTACK_TTY_DEV replaces /dev/tty, the tests use it.
have_input_source() {
	[[ -n "${DPISTACK_INPUT:-}" ]] && return 0
	[[ -t 0 ]] && return 0
	{ : <"${DPISTACK_TTY_DEV:-/dev/tty}"; } 2>/dev/null
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
		die 2 "no terminal for the menu, use -y or DPISTACK_INPUT"
	fi
	MENU_SHOW_ADVANCED=$([[ "$ADVANCED" == "1" ]] && echo 1 || echo 0)
	MENU_FAST="$FAST"
	menu_run_install
}

maybe_run_reconfigure_menu() {
	if [[ "$NON_INTERACTIVE" == "1" ]]; then
		return 0
	fi
	if ! have_input_source; then
		die 2 "no terminal for the menu, use -y or DPISTACK_INPUT"
	fi
	MENU_SHOW_ADVANCED=$([[ "$ADVANCED" == "1" ]] && echo 1 || echo 0)
	menu_run_reconfigure
	# "Back" from the management menu: nothing to apply.
	[[ $? -eq 20 ]] && exit 0
}

validate_or_die() {
	local out rc
	out=$(config_validate)
	rc=$?
	if [[ "$rc" -ne 0 ]]; then
		echo "The config failed validation:" >&2
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
		if step_call check "$name"; then
			echo "[$i/$total] $name ... no changes"
		else
			any_pending=1
			echo "[$i/$total] $name ... needs applying"
			step_call plan "$name" | sed 's/^/    /'
		fi
	done
	return "$any_pending"
}

# autodetect_iface - IFACES still holds the schema default enp2s0 and that
# interface does not exist here (eth0, ens3, a renamed NIC...): take the
# interface of the default route instead of failing the preflight. A
# value anyone typed is never replaced.
autodetect_iface() {
	[[ "${CONF[IFACES]:-}" == "enp2s0" ]] && ! net_iface_exists enp2s0 || return 0
	local found
	found=$(net_default_iface)
	[[ -n "$found" ]] || return 0
	echo "IFACES: interface enp2s0 does not exist, took $found (the default-route interface)" >&2
	CONF[IFACES]="$found"
}

# ensure_preflight_tools - the preflight itself calls ss and curl, and a
# minimal image has neither: install them first, but only when missing
# and only for a real run.
ensure_preflight_tools() {
	[[ "$DRY_RUN" == "1" || "${EUID:-$(id -u)}" -ne 0 ]] && return 0
	command -v ss >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && return 0
	pkg_update_once || die 1 "updating the package index failed"
	case "$OS_FAMILY" in
	apt) pkg_install iproute2 curl ca-certificates || die 1 "could not install iproute2 and curl" ;;
	esac
}

# install_command_early - the selfinstall step does not depend on any
# component, so it runs before the preflight and a failed preflight no
# longer leaves a host without the `dpistack` command. A failure here is a
# warning: the install itself can still go on from the clone.
install_command_early() {
	[[ "$DRY_RUN" == "1" || "${EUID:-$(id -u)}" -ne 0 ]] && return 0
	step_selected selfinstall || return 0
	step_selfinstall_check && return 0
	if step_selfinstall_apply; then
		echo "the command dpistack is installed in $(path_sbin_dir)" >&2
	else
		echo "warning: could not install the dpistack command, the install goes on from this directory" >&2
	fi
}

# prepare_packages - the package index and the base tools come first, so
# every later step finds its packages. A component whose package does not
# exist here falls back to a source build, and the changed source is saved
# to dpistack.conf and checked against the preflight again (a build needs
# more disk than a package).
prepare_packages() {
	pkg_update_once || die 1 "updating the package index failed"
	pkg_install_base || die 1 "could not install the base packages"
	pkg_enable_extra_repos || die 1 "could not enable the extra repositories (EPEL, CRB)"
	local fallback=0
	suricata_resolve_source && fallback=1
	ndpi_resolve_source && fallback=1
	if [[ "$fallback" == "1" ]]; then
		if [[ "$DRY_RUN" != "1" ]]; then
			config_write_conf "$(path_conf)"
			config_snapshot_applied
		fi
		step_preflight_check || exit 3
	fi
}

run_apply() {
	local total=${#STEPS_ORDER[@]}
	local i=0
	for name in "${STEPS_ORDER[@]}"; do
		i=$((i + 1))
		step_selected "$name" || continue
		if step_call check "$name"; then
			continue
		fi
		if ! step_call apply "$name"; then
			die 1 "step $name failed, to continue: install.sh install --only $name"
		fi
		if step_call check "$name"; then
			state_set_step_done "$name"
			echo "[$i/$total] $name ... done"
		else
			# A step can legitimately still report drift after a clean
			# apply (5.4: a manually edited file is left alone with a
			# notice, not overwritten) - that isn't a failed apply.
			echo "[$i/$total] $name ... partly applied, see the notes above"
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
	autodetect_iface

	echo "Final config:"
	config_print_summary
	if [[ "$PANEL_PASSWORD_JUST_GENERATED" == "1" ]]; then
		echo "Panel password created (save it: it is shown nowhere else, only a hash stays on disk): $PANEL_PASSWORD_GENERATED_VALUE"
	fi

	if [[ "$DRY_RUN" != "1" ]]; then
		config_write_conf "$(path_conf)"
		config_snapshot_applied
		config_write_secrets "$(path_secrets)"
	fi

	ensure_preflight_tools

	# The persistent command comes first: when the preflight below stops the
	# install, `sudo dpistack` still exists and the saved answers are still
	# there, so the next run is `sudo dpistack install` after the fix.
	install_command_early

	if ! step_preflight_check; then
		echo "preflight failed, nothing was installed. Your answers are saved in $(path_conf)." >&2
		echo "Fix the problems above (or change the setting named in the message), then run: sudo dpistack install" >&2
		exit 3
	fi

	prepare_packages

	run_plan
	local pending=$?

	if [[ "$DRY_RUN" == "1" ]]; then
		echo "dry-run: the plan is shown, the config is not written"
		return 0
	fi

	if [[ "$pending" -ne 0 ]]; then
		run_apply
		selinux_relabel_installed
	fi
	verify_final_report
	panel_report_metrics
	state_write_value install.finished yes
	echo "installation finished"
	return 0
}

cmd_reconfigure() {
	validate_step_names "$ONLY_STEPS" "--only"
	validate_step_names "$SKIP_STEPS" "--skip"
	lock_acquire
	os_detect

	if [[ ! -f "$(path_conf)" ]]; then
		die 2 "config not found, run first: install.sh install"
	fi

	layer_config_common
	maybe_run_reconfigure_menu
	config_generate_metrics_token_if_needed
	validate_or_die

	config_diff_and_steps "$(path_conf)"

	if [[ "$CONFIG_CHANGE_WEIGHT" == "none" ]]; then
		echo "no changes"
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
					die 3 "heavy changes in non-interactive mode need --force"
				fi
			else
				die 3 "heavy changes need confirmation, there is no terminal to ask"
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
					die 1 "suricata -T failed on the new suricata.yaml, changes not applied (see the output above)"
				fi
			fi
		done
	fi

	panel_password_apply
	config_write_conf "$(path_conf)"
	config_snapshot_applied
	config_write_secrets "$(path_secrets)"

	# A changed key can make a step install a package (nginx, a new version).
	if [[ "${#CONFIG_AFFECTED_STEPS[@]}" -gt 0 ]]; then
		pkg_update_once || die 1 "updating the package index failed"
	fi
	for step in "${CONFIG_AFFECTED_STEPS[@]}"; do
		step_selected "$step" || continue
		if ! step_call apply "$step"; then
			die 1 "step $step failed during reconfigure"
		fi
	done
	selinux_relabel_installed

	panel_report_metrics
	echo "config applied"
	return 0
}

cmd_upgrade() {
	lock_acquire
	os_detect
	if [[ ! -f "$(path_conf)" ]]; then
		die 2 "config not found, run first: install.sh install"
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
		echo "nothing to upgrade"
		return 0
	fi

	if [[ "${CONF[PIN_VERSIONS]:-no}" == "yes" ]]; then
		echo "upgrade: PIN_VERSIONS=yes - the package manager will skip pinned packages (apt-mark hold, dnf versionlock): ${packages[*]}"
	fi
	# Without a fresh index an upgrade never sees a newer version.
	pkg_update_once || die 1 "updating the package index failed"
	pkg_upgrade "${packages[@]}" || die 1 "upgrading packages failed"
	return 0
}

# uninstall removes only what dpistack itself created (its own units,
# its own rendered nginx snippet, its own conf/state). It never stops,
# disables, or removes the underlying Suricata/Redis/ntopng/EveBox
# packages or services - "keeps data and configs" (5.7) reads most
# safely as "leave the working stack alone", not as "tear down a
# production IDS because its manager was uninstalled". --purge extends
# this to those components' own rendered configs/data, but still never
# touches packages (5.7's exemption for pre-existing packages is hard
# to honour precisely without real install-provenance tracking, so the
# conservative reading - never remove packages at all - was chosen).
# uninstall_rm_tree <path> - rm -rf of one directory dpistack made. Refuses
# an empty path or "/" so that a wrong variable can never reach the host.
uninstall_rm_tree() {
	local d="$1"
	[[ -n "$d" && "$d" != "/" && "$d" != "${DPISTACK_ROOT}/" ]] || return 0
	rm -rf -- "$d"
}

# uninstall_docker_stack <purge> - the containers of the docker runtime are
# dpistack's own: the compose project is taken down (containers of other
# projects are not in it), the compose file goes, and the panel images
# dpistack built go. With purge the pulled images go too, but `docker image
# rm` refuses an image that another container still uses, so those stay.
uninstall_docker_stack() {
	local purge="$1" svc img
	command -v docker >/dev/null 2>&1 || return 0
	if [[ -f "$(path_compose_yaml)" ]]; then
		docker_compose_argv
		run "${DOCKER_COMPOSE_ARGV[@]}" down --remove-orphans || echo "warning: docker compose down failed, the containers may need a manual removal" >&2
	fi
	while read -r img; do
		if [[ -n "$img" ]]; then run docker image rm "$img" >/dev/null 2>&1 || true; fi
	done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^dpistack-panel:' || true)
	if [[ "$purge" == "1" ]]; then
		for svc in suricata evebox ntopng redis victoriametrics prometheus node_exporter grafana; do
			img=$(docker_image "$svc" 2>/dev/null) || continue
			if [[ -n "$img" ]]; then run docker image rm "$img" >/dev/null 2>&1 || true; fi
		done
	fi
	rm -f "$(path_compose_yaml)"
	rmdir "$(dirname "$(path_compose_yaml)")" 2>/dev/null || true
}

# uninstall_built_from_source - Suricata and nDPI built by dpistack leave
# files in /usr/local; the build tree knows exactly which ones, so the build
# system's own uninstall target removes them and nothing else.
uninstall_built_from_source() {
	local d
	for d in "$(path_suricata_src_dir)" "$(path_ndpi_src_dir)"; do
		if [[ -f "$d/Makefile" ]]; then run make -C "$d" uninstall >/dev/null 2>&1 || true; fi
		uninstall_rm_tree "$d"
	done
	rm -f "$(path_suricata_ndpi_plugin)"
}

cmd_uninstall() {
	lock_acquire
	os_detect

	if [[ ! -f "$(path_conf)" ]]; then
		echo "nothing to remove"
		return 0
	fi

	layer_config_common

	if [[ "$DRY_RUN" == "1" ]]; then
		# Everything below removes files with plain rm: a dry run only lists.
		echo "dry-run: uninstall would stop and remove the dpistack timers and services, the DPISTACK chain, the mode drop-in (Suricata running in NFQ is restarted), the ufw/firewalld rules dpistack added, the configs ($(path_conf), $(path_secrets)), the state ($(path_state_dir)) and the program copies; nothing changed"
		[[ "$PURGE" == "1" ]] && echo "dry-run: with --purge also the configs and component data (suricata.yaml, rules, ntopng, EveBox, TLS, metrics data, users)"
		return 0
	fi

	run systemctl disable --now "$RULES_TIMER" 2>/dev/null || true
	rm -f "$(path_rules_timer_unit)" "$(path_rules_service_unit)"
	run systemctl daemon-reload

	# The DPISTACK chain and the boot unit that restores it are dpistack's
	# own; foreign chains and rules are not touched (lib/ips.sh).
	if [[ "$DRY_RUN" == "1" ]]; then
		echo "dry-run: iptables: remove the jumps to DPISTACK and the chain itself, delete $(path_fw_unit)"
	else
		ips_fw_remove
	fi
	run systemctl disable dpistack-fw.service 2>/dev/null || true
	# Suricata started by the IPS drop-in sits on the queue (-q 0). With the
	# drop-in gone it must be started again, or it keeps listening to a queue
	# that nothing feeds any more instead of capturing like a plain install.
	local was_ips=0
	[[ -e "$(path_suricata_mode_dropin)" ]] && was_ips=1
	rm -f "$(path_fw_unit)" "$(path_suricata_mode_dropin)"
	run systemctl daemon-reload
	if [[ "$was_ips" == 1 && "${CONF[SURICATA_SOURCE]:-}" != "source" ]]; then
		run systemctl restart "$SURICATA_UNIT" 2>/dev/null || true
	fi

	# ufw and firewalld rules that dpistack added (and only those).
	access_firewall_forget || true

	# The metrics backend is dpistack's own addition (unlike the packages of
	# the stack): stopped, its unit and binaries removed; the series stay
	# unless --purge.
	if [[ -n "$(metrics_installed)" ]]; then
		metrics_stop_installed || true
		rm -f "$(path_vm_unit)" "$(path_prometheus_unit)" "$(path_vm_bin)" "$(path_prometheus_bin)"
		run systemctl daemon-reload
	fi

	# node_exporter and Grafana are dpistack's own additions too.
	if [[ -n "$(nodeexp_installed)" ]]; then
		nodeexp_stop_installed || true
		rm -f "$(path_nodeexp_unit)" "$(path_nodeexp_bin)"
	fi
	if [[ -n "$(grafana_installed)" ]]; then
		grafana_stop_installed || true
		rm -rf "$(path_grafana_unit)" "$(path_grafana_home)"
	fi
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
		rm -rf "$(path_metrics_data_dir)"
		if id "$METRICS_USER" >/dev/null 2>&1; then
			run userdel "$METRICS_USER" || true
		fi
		if id "$PANEL_USER" >/dev/null 2>&1; then
			run userdel "$PANEL_USER" || true
		fi
		# dpistack's own data and additions of the stack (never the packages)
		uninstall_rm_tree "$(path_evebox_data_dir)"
		uninstall_rm_tree "$(path_grafana_data_dir)"
		rm -f "$(path_evebox_apt_list)" "$(path_evebox_keyring)" "$(path_ntop_repo_file)"
		uninstall_built_from_source
		echo "uninstall --purge: configs and component data removed (packages, Docker itself and anything dpistack did not create are untouched)"
	fi

	# dpistack's own small files, with or without --purge
	rm -f "$(path_metrics_token)" "$(path_grafana_ini)"
	uninstall_rm_tree "$(path_grafana_prov_dir)"

	run systemctl disable --now "$WATCH_TIMER" 2>/dev/null || true
	rm -f "$(path_watch_timer_unit)" "$(path_watch_service_unit)" "$(path_sudoers)"
	run systemctl disable --now "$PANEL_SERVICE" 2>/dev/null || true
	# every container of the docker runtime, not only the panel
	uninstall_docker_stack "$PURGE"
	rm -f "$(path_panel_service_unit)" "$(path_panel_bin)"
	run systemctl daemon-reload

	rm -f "$(path_conf)" "$(path_conf_draft)" "$(path_secrets)" "$(path_panel_auth)"
	rmdir "$(dirname "$(path_conf)")" 2>/dev/null || true
	rmdir "${DPISTACK_ROOT}/opt/dpistack" "$(path_log_dir)" 2>/dev/null || true
	rm -rf "$(path_state_dir)"

	# Last, because `dpistack uninstall` runs from the copy it removes.
	rm -f "$(path_dpistack_bin)" "$(path_retired_ctl)" "$(path_watch_bin)"
	rm -rf "$(path_installer_copy_dir)"

	# The install log goes last: every step above still writes to it.
	[[ "$PURGE" == "1" ]] && uninstall_rm_tree "$(path_log_dir)"

	echo "done"
	return 0
}

cmd_status() {
	os_detect
	layer_config_common
	local name
	for name in "${STEPS_ORDER[@]}"; do
		if step_call check "$name"; then
			echo "$name: ok"
		else
			echo "$name: mismatch"
		fi
	done
}

# cmd_diag - one text report for a bug report: system, versions,
# repositories, configuration without secrets, service state and the tail
# of the logs. Read-only. The report also goes to a file (DIAG_OUT, else a
# new private mktemp file); tokens, passwords and credentials in URLs are
# replaced before anything is printed.
diag_section() {
	printf '\n===== %s =====\n' "$1"
	shift
	"$@" 2>&1 || echo "(rc=$?)"
}

diag_tool_versions() {
	local tool
	for tool in suricata evebox ntopng nginx redis-server rustc gcc git curl; do
		if command -v "$tool" >/dev/null 2>&1; then
			printf '%s: ' "$tool"
			"$tool" --version 2>&1 | head -n 1
		else
			echo "$tool: missing"
		fi
	done
}

diag_packages() {
	case "$OS_FAMILY" in
	apt) dpkg -l 2>/dev/null | grep -E ' (suricata|libndpi|ntopng|evebox|redis|nginx|ufw|iproute2)' ;;
	dnf) rpm -qa 2>/dev/null | grep -Ei '^(suricata|ndpi|ntopng|evebox|redis|valkey|nginx|firewalld)' ;;
	esac
}

diag_repos() {
	case "$OS_FAMILY" in
	apt)
		grep -hvE '^[[:space:]]*(#|$)' "$(path_apt_dir)/sources.list" "$(path_apt_dir)"/sources.list.d/*.list "$(path_apt_dir)"/sources.list.d/*.sources 2>/dev/null
		;;
	dnf)
		dnf -q repolist 2>&1
		;;
	esac
}

diag_units() {
	local unit
	for unit in "$SURICATA_UNIT" "$REDIS_UNIT" "$EVEBOX_UNIT" "$NTOPNG_UNIT" "$NGINX_UNIT" "$WATCH_TIMER"; do
		printf '%-28s active=%s enabled=%s\n' "$unit" \
			"$(systemctl is-active "$unit" 2>&1)" "$(systemctl is-enabled "$unit" 2>&1)"
	done
	systemctl --failed --no-pager 2>&1 | head -n 15
}

diag_report() {
	echo "dpistack v${DPISTACK_VERSION}, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	diag_section "platform" bash -c "echo \"$OS_ID $OS_VERSION_ID family=$OS_FAMILY level=\$1\"; cat \"$(path_os_release)\"; uname -a; nproc; free -m | sed -n 1,2p; df -h / | tail -n 1" _ "$(os_support_level)"
	diag_section "versions" diag_tool_versions
	if command -v suricata >/dev/null 2>&1; then
		diag_section "suricata --build-info" bash -c 'suricata --build-info 2>&1 | grep -E "^This is|Rust|nDPI|AF_PACKET|Features"'
	fi
	diag_section "packages" diag_packages
	diag_section "repositories" diag_repos
	diag_section "dpistack.conf" cat "$(path_conf)"
	diag_section "state" bash -c "grep -vE '^(file_hash|applied)\\.' \"$(path_state_file)\" 2>/dev/null"
	diag_section "services" diag_units
	diag_section "network" bash -c "ip -br addr 2>/dev/null; ss -ltn 2>/dev/null | head -n 25"
	diag_section "SELinux and firewall" bash -c "getenforce 2>&1; (ufw status 2>/dev/null || firewall-cmd --state 2>&1) | head -n 8"
	if command -v suricata >/dev/null 2>&1 && [[ -f "$(path_suricata_yaml)" ]]; then
		diag_section "suricata -T" bash -c "suricata -T -c \"$(path_suricata_yaml)\" 2>&1 | tail -n 12"
	fi
	diag_section "dpistack log (last 80 lines)" bash -c "tail -n 80 \"$(path_install_log)\" 2>&1"
	if command -v journalctl >/dev/null 2>&1; then
		diag_section "journalctl (suricata, evebox, ntopng)" bash -c 'journalctl -u suricata -u evebox -u ntopng -n 40 --no-pager 2>&1'
	fi
}

cmd_diag() {
	os_detect >/dev/null 2>&1 || true
	local out="${DIAG_OUT:-$(mktemp -t dpistack-diag.XXXXXX)}"
	diag_report 2>&1 |
		sed -E 's/((TOKEN|PASSWORD|PASS|SECRET)[A-Z_]*=).*/\1<hidden>/; s#(://)[^/@[:space:]]+:[^/@[:space:]]+@#\1<hidden>@#g' |
		tee "$out"
	echo "report saved: $out" >&2
}

# require_root - dpistack changes the system and reads secrets: it runs as
# root or not at all. The panel gets there through `sudo -n`, which makes
# the process root as well.
require_root() {
	if [[ "$(id -u)" -ne 0 ]]; then
		echo "dpistack: the command runs as root only (sudo dpistack ...)" >&2
		exit 1
	fi
}

# The verbs that act on an installed system (tech.md 4.5). `status` and
# `reconfigure` also exist as installer commands: see dispatch_ctl.
CTL_VERBS=(status start stop restart reload logs config-read config-write config-revert settings
	reconfigure rules-update rules-sources rules-group rules-sid rules-search iface mode
	mode-confirm mode-rollback fw panel-passwd test health version self-update)

# restricted_caller - the panel (and nothing else) comes through sudo as
# the panel user. It gets the verbs above and no installer command: a stolen
# panel session cannot run install, uninstall or upgrade. The one exception is
# `self-update run|job` (the Update button): it installs only a newer release
# of the project itself, never anything the caller names.
restricted_caller() {
	[[ -n "${SUDO_USER:-}" && "$SUDO_USER" == "$PANEL_USER" ]] ||
		[[ "${DPISTACK_CALLER:-}" == "panel" ]]
}

# dispatch_ctl <args...> - returns 0 after running a verb (the caller exits
# with its code through exit inside ctl_main); returns 1 when the arguments
# are an installer command.
dispatch_ctl() {
	local verb="${1:-}" arg
	# The panel is restricted to the control verbs. DPISTACK_VERBS_ONLY=1 is
	# a test hook: every argument is a verb, `reconfigure` included.
	if [[ "$VERBS_ONLY" == "1" ]] || restricted_caller; then
		ctl_main "$@"
		exit $?
	fi
	in_list "$verb" "${CTL_VERBS[@]}" || return 1
	case "$verb" in
	reconfigure)
		# `reconfigure --light` is the non-interactive, light-only form.
		local -a rest=()
		local light=0
		shift
		for arg in "$@"; do
			if [[ "$arg" == "--light" ]]; then light=1; else rest+=("$arg"); fi
		done
		((light)) || return 1
		ctl_main reconfigure "${rest[@]}"
		exit $?
		;;
	status)
		if [[ "${2:-}" == "--json" ]]; then
			ctl_main "$@"
			exit $?
		fi
		return 1
		;;
	esac
	ctl_main "$@"
	exit $?
}

main() {
	require_root
	dispatch_ctl "$@" || true
	# No command: the menu that fits the state. Without a terminal or
	# DPISTACK_INPUT parse_args prints the usage as before.
	if [[ $# -eq 0 ]] && have_input_source; then
		if [[ "$BIN_NAME" == "dpistack" && -f "$(path_conf)" ]]; then
			os_detect
			menu_run_manage
			exit 0
		fi
		set -- install
	fi
	# An option first (`install.sh --fast`): the command is install.
	if [[ "${1:-}" == -* && "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
		set -- install "$@"
	fi
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
		# Components first (what runs), then the installer's own check of
		# every step (what differs from the configuration).
		ctl_main status
		echo
		echo "Install steps:"
		cmd_status
		;;
	diag)
		cmd_diag
		;;
	help | -h | --help)
		usage
		echo
		ctl_usage
		;;
	*)
		echo "unknown command: $COMMAND" >&2
		usage
		exit 2
		;;
	esac
}

main "$@"
