#!/usr/bin/env bash
# "watch" step: the systemd service and timer of dpistack-watch (tech.md
# 8). The binary itself is placed by the selfinstall step, which runs
# before this one. jq is a hard dependency of the watchdog, so the step
# installs it. The service skips its run while the installer copy is
# missing, see the ConditionPathExists lines in the template.

WATCH_TIMER="dpistack-watch.timer"

watch_enabled() {
	[[ "${CONF[WATCH_ENABLE]:-yes}" == "yes" ]]
}

watch_render_service() {
	render_template "$SCRIPT_DIR/templates/dpistack-watch.service.tpl" \
		"LIB_DIR=$(path_installer_copy_dir)/lib" \
		"CTL_BIN=$(path_ctl_bin)" \
		"WATCH_BIN=$(path_watch_bin)"
}

watch_render_timer() {
	render_template "$SCRIPT_DIR/templates/dpistack-watch.timer.tpl" \
		"INTERVAL=${CONF[WATCH_INTERVAL_SEC]:-60}"
}

watch_file_matches() {
	# watch_file_matches <path> <expected-content>
	[[ -f "$1" ]] || return 1
	[[ "$(printf '%s\n' "$2" | state_hash_content)" == "$(state_hash_content <"$1")" ]]
}

step_watch_check() {
	if ! watch_enabled; then
		[[ ! -f "$(path_watch_timer_unit)" && ! -f "$(path_watch_service_unit)" ]]
		return
	fi
	command -v jq >/dev/null 2>&1 || return 1
	[[ -x "$(path_watch_bin)" ]] || return 1
	watch_file_matches "$(path_watch_service_unit)" "$(watch_render_service)" || return 1
	watch_file_matches "$(path_watch_timer_unit)" "$(watch_render_timer)" || return 1
	return 0
}

step_watch_apply() {
	if ! watch_enabled; then
		if [[ "${DRY_RUN:-0}" != "1" && (-f "$(path_watch_timer_unit)" || -f "$(path_watch_service_unit)") ]]; then
			run systemctl disable --now "$WATCH_TIMER"
			rm -f "$(path_watch_timer_unit)" "$(path_watch_service_unit)"
			run systemctl daemon-reload
		fi
		return 0
	fi

	command -v jq >/dev/null 2>&1 || pkg_install jq
	write_rendered_file "$(path_watch_service_unit)" "$(watch_render_service)"
	write_rendered_file "$(path_watch_timer_unit)" "$(watch_render_timer)"
	run systemctl daemon-reload || return 1
	run systemctl enable --now "$WATCH_TIMER" || return 1
	# A changed interval needs the timer restarted to take effect.
	run systemctl restart "$WATCH_TIMER" || return 1
	return 0
}

step_watch_plan() {
	if watch_enabled; then
		echo "watch: $(path_watch_bin), таймер каждые ${CONF[WATCH_INTERVAL_SEC]:-60} с"
	else
		echo "watch: WATCH_ENABLE=no, таймер не нужен"
	fi
}
