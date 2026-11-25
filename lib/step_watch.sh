#!/usr/bin/env bash
# "watch" step: the systemd service and timer of dpistack-watch (section
# 8). The binary itself is placed by the selfinstall step, which runs
# before this one. jq is a hard dependency of the watchdog, so the step
# installs it. The service skips its run while the installer copy is
# missing, see the ConditionPathExists lines in the template.

WATCH_TIMER="dpistack-watch.timer"
BACKUP_TIMER="dpistack-backup.timer"

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

backup_enabled() {
	[[ "${CONF[BACKUP_SCHEDULE]:-off}" != "off" ]]
}

backup_render_service() {
	render_template "$SCRIPT_DIR/templates/dpistack-backup.service.tpl" \
		"LIB_DIR=$(path_installer_copy_dir)/lib" \
		"CTL_BIN=$(path_ctl_bin)"
}

backup_render_timer() {
	render_template "$SCRIPT_DIR/templates/dpistack-backup.timer.tpl" \
		"SCHEDULE=${CONF[BACKUP_SCHEDULE]:-off}"
}

# backup_units_check - 0 when the scheduled backup units are what the config
# asks for (present and current, or absent when BACKUP_SCHEDULE=off).
backup_units_check() {
	if ! backup_enabled; then
		[[ ! -f "$(path_backup_timer_unit)" && ! -f "$(path_backup_service_unit)" ]]
		return
	fi
	if [[ -n "${CONF[BACKUP_AGE_RECIPIENT]:-}" ]]; then
		command -v age >/dev/null 2>&1 || return 1
	fi
	watch_file_matches "$(path_backup_service_unit)" "$(backup_render_service)" || return 1
	watch_file_matches "$(path_backup_timer_unit)" "$(backup_render_timer)" || return 1
}

# backup_units_apply - writes or removes the units of the scheduled backup.
# The archives already in BACKUP_DIR are never touched here.
backup_units_apply() {
	if ! backup_enabled; then
		if [[ "${DRY_RUN:-0}" != "1" && (-f "$(path_backup_timer_unit)" || -f "$(path_backup_service_unit)") ]]; then
			run systemctl disable --now "$BACKUP_TIMER"
			rm -f "$(path_backup_timer_unit)" "$(path_backup_service_unit)"
			run systemctl daemon-reload
		fi
		return 0
	fi
	if [[ -n "${CONF[BACKUP_AGE_RECIPIENT]:-}" ]]; then
		command -v age >/dev/null 2>&1 || pkg_install age || {
			echo "backup: BACKUP_AGE_RECIPIENT is set and age cannot be installed; install age or clear the key" >&2
			return 1
		}
	fi
	mkdir -p "${DPISTACK_ROOT}${CONF[BACKUP_DIR]:-/var/backups/dpistack}" && chmod 0700 "${DPISTACK_ROOT}${CONF[BACKUP_DIR]:-/var/backups/dpistack}"
	write_rendered_file "$(path_backup_service_unit)" "$(backup_render_service)"
	write_rendered_file "$(path_backup_timer_unit)" "$(backup_render_timer)"
	run systemctl daemon-reload || return 1
	run systemctl enable --now "$BACKUP_TIMER" || return 1
	run systemctl restart "$BACKUP_TIMER" || return 1
}

watch_file_matches() {
	# watch_file_matches <path> <expected-content>
	[[ -f "$1" ]] || return 1
	[[ "$(printf '%s\n' "$2" | state_hash_content)" == "$(state_hash_content <"$1")" ]]
}

step_watch_check() {
	backup_units_check || return 1
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
	backup_units_apply || return 1
	if ! watch_enabled; then
		if [[ "${DRY_RUN:-0}" != "1" && (-f "$(path_watch_timer_unit)" || -f "$(path_watch_service_unit)") ]]; then
			run systemctl disable --now "$WATCH_TIMER"
			rm -f "$(path_watch_timer_unit)" "$(path_watch_service_unit)"
			run systemctl daemon-reload
		fi
		return 0
	fi

	command -v jq >/dev/null 2>&1 || pkg_install jq || return 1
	write_rendered_file "$(path_watch_service_unit)" "$(watch_render_service)"
	write_rendered_file "$(path_watch_timer_unit)" "$(watch_render_timer)"
	run systemctl daemon-reload || return 1
	run systemctl enable --now "$WATCH_TIMER" || return 1
	# A changed interval needs the timer restarted to take effect.
	run systemctl restart "$WATCH_TIMER" || return 1
	return 0
}

step_watch_plan() {
	if backup_enabled; then
		echo "backup: ${CONF[BACKUP_SCHEDULE]}, keep ${CONF[BACKUP_KEEP]:-7} in ${CONF[BACKUP_DIR]:-/var/backups/dpistack}${CONF[BACKUP_AGE_RECIPIENT]:+, encrypted with age}"
	else
		echo "backup: BACKUP_SCHEDULE=off, no timer is needed"
	fi
	if watch_enabled; then
		echo "watch: $(path_watch_bin), timer every ${CONF[WATCH_INTERVAL_SEC]:-60} s"
	else
		echo "watch: WATCH_ENABLE=no, no timer is needed"
	fi
}
