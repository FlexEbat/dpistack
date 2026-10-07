#!/usr/bin/env bash
# "panel" step. Slice 10 covers the part dpistack-ctl needs: the system
# user `dpistack` and the sudoers rule that lets it run only
# dpistack-ctl (tech.md 4.2, 4.5). The panel binary and unit come with
# the panel slices.

PANEL_USER="dpistack"

panel_render_sudoers() {
	render_template "$SCRIPT_DIR/templates/sudoers.tpl" \
		"PANEL_USER=$PANEL_USER" \
		"CTL_BIN=$(path_ctl_bin)"
}

step_panel_check() {
	getent passwd "$PANEL_USER" >/dev/null 2>&1 || return 1

	local path
	path=$(path_sudoers)
	[[ -f "$path" ]] || return 1
	local expected actual
	expected=$(panel_render_sudoers | state_hash_content)
	actual=$(state_hash_content <"$path")
	[[ "$expected" == "$actual" ]] || return 1
	[[ "$(stat -c %a "$path")" == "440" ]] || return 1
	return 0
}

step_panel_apply() {
	if ! getent passwd "$PANEL_USER" >/dev/null 2>&1; then
		run useradd --system --no-create-home --shell /usr/sbin/nologin "$PANEL_USER" || return 1
	fi
	# eve.json belongs to the suricata group (4.2: the user reads it).
	if getent group suricata >/dev/null 2>&1; then
		run usermod -a -G suricata "$PANEL_USER" || return 1
	fi

	# A broken sudoers file locks sudo out, so visudo checks a temp copy
	# before anything lands in /etc/sudoers.d.
	local content tmp
	content=$(panel_render_sudoers) || return 1
	if [[ "${DRY_RUN:-0}" != "1" ]]; then
		tmp=$(mktemp)
		printf '%s\n' "$content" >"$tmp"
		if ! visudo -cf "$tmp" >&2; then
			rm -f "$tmp"
			log "ERROR" "panel: visudo отклонил правило sudoers"
			return 1
		fi
		rm -f "$tmp"
	fi
	write_rendered_file "$(path_sudoers)" "$content"
	run chmod 0440 "$(path_sudoers)" || return 1
	return 0
}

step_panel_plan() {
	echo "panel: пользователь $PANEL_USER, sudoers $(path_sudoers) (только dpistack-ctl)"
}
