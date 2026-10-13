#!/usr/bin/env bash
# "panel" step: the system user `dpistack`, the sudoers rule that lets it
# run only dpistack-ctl (tech.md 4.2, 4.5), the panel binary (PANEL_SOURCE:
# built from panel/ with Go, or a ready dpistack-panel next to install.sh)
# and the systemd unit with the resource budget (tech.md 9).

PANEL_USER="dpistack"
PANEL_SERVICE="dpistack-panel.service"
PANEL_SRC_HASH_KEY="panel.src_hash"

panel_source_mode() {
	echo "${CONF[PANEL_SOURCE]:-build}"
}

# panel_prebuilt_path - where a ready binary has to lie for prebuilt.
panel_prebuilt_path() {
	echo "$SCRIPT_DIR/dpistack-panel"
}

# panel_src_hash - one hash over everything the binary is built from, so
# a changed source or web file rebuilds it and an unchanged one does not.
panel_src_hash() {
	[[ -d "$SCRIPT_DIR/panel" ]] || return 1
	(cd "$SCRIPT_DIR/panel" &&
		find . -type f \( -name '*.go' -o -name go.mod -o -name go.sum -o -path './web/*' \) -print0 |
		sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

# panel_args - the flags of the panel (tech.md 9). The panel does not read
# dpistack.conf, so LAN_CIDR=auto is resolved here.
panel_args() {
	local mode="${CONF[ACCESS_MODE]:-localhost}" port="${CONF[PANEL_PORT]:-9800}"
	local host="127.0.0.1" args cidr=""
	[[ "$mode" == "lan" ]] && host="0.0.0.0"
	if [[ "$mode" != "localhost" ]]; then
		cidr=$(access_effective_lan_cidr) || cidr=""
		if [[ "$mode" == "lan" && -z "$cidr" ]]; then
			# The same closed fallback as the access step: nobody but the
			# host itself gets in until LAN_CIDR is set by hand.
			echo "panel: LAN_CIDR не определить, панель открыта только для 127.0.0.1 (задайте LAN_CIDR)" >&2
			cidr="127.0.0.1/32"
		fi
	fi
	args="-addr ${host}:${port} -access ${mode}"
	[[ -n "$cidr" ]] && args+=" -lan-cidr ${cidr}"
	args+=" -auth-file $(path_panel_auth) -health-file $(path_health_json) -ctl $(path_ctl_bin)"
	echo "$args"
}

panel_render_service() {
	local args
	args=$(panel_args) || return 1
	render_template "$SCRIPT_DIR/templates/dpistack-panel.service.tpl" \
		"USER=$PANEL_USER" \
		"PANEL_BIN=$(path_panel_bin)" \
		"ARGS=$args"
}

panel_unit_matches() {
	local path expected
	path=$(path_panel_service_unit)
	[[ -f "$path" ]] || return 1
	expected=$(panel_render_service) || return 1
	[[ "$(printf '%s\n' "$expected" | state_hash_content)" == "$(state_hash_content <"$path")" ]]
}

# panel_bin_current - the installed binary is the one this run would install.
panel_bin_current() {
	local bin src
	bin=$(path_panel_bin)
	[[ -x "$bin" ]] || return 1
	if [[ "$(panel_source_mode)" == "prebuilt" ]]; then
		cmp -s "$(panel_prebuilt_path)" "$bin"
		return
	fi
	# Without the sources (an installer copy) there is nothing to rebuild from.
	src=$(panel_src_hash) || return 0
	[[ "$(state_read_value "$PANEL_SRC_HASH_KEY")" == "$src" ]]
}

panel_bin_install() {
	local bin tmp
	bin=$(path_panel_bin)
	if [[ "$(panel_source_mode)" == "prebuilt" ]]; then
		run install -D -m 0755 "$(panel_prebuilt_path)" "$bin" || return 1
		return 0
	fi
	tmp=$(mktemp) || return 1
	if ! (cd "$SCRIPT_DIR/panel" &&
		run env CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$tmp" ./cmd/panel); then
		rm -f "$tmp"
		log "ERROR" "panel: сборка не удалась (нужен Go не старее версии в panel/go.mod; готовый бинарник: PANEL_SOURCE=prebuilt)"
		return 1
	fi
	run install -D -m 0755 "$tmp" "$bin" || {
		rm -f "$tmp"
		return 1
	}
	rm -f "$tmp"
	[[ "${DRY_RUN:-0}" == "1" ]] || state_write_value "$PANEL_SRC_HASH_KEY" "$(panel_src_hash)"
	return 0
}

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

	panel_bin_current || return 1
	panel_unit_matches || return 1
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

	# panel.auth is written before this step, when the group is missing.
	if [[ -f "$(path_panel_auth)" ]]; then
		run chown root:dpistack "$(path_panel_auth)" || return 1
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
	write_rendered_file "$(path_sudoers)" "$content" 0440
	run chmod 0440 "$(path_sudoers)" || return 1

	# A changed binary or unit needs a restart; a first install only a start.
	local restart=0
	panel_bin_current || {
		panel_bin_install || return 1
		restart=1
	}
	panel_unit_matches || restart=1
	local unit
	unit=$(panel_render_service) || return 1
	write_rendered_file "$(path_panel_service_unit)" "$unit"
	run systemctl daemon-reload || return 1
	run systemctl enable --now "$PANEL_SERVICE" || return 1
	if [[ "$restart" == "1" ]]; then
		run systemctl restart "$PANEL_SERVICE" || return 1
	fi
	return 0
}

step_panel_plan() {
	echo "panel: пользователь $PANEL_USER, sudoers $(path_sudoers) (только dpistack-ctl), бинарник $(path_panel_bin) (PANEL_SOURCE=$(panel_source_mode)), юнит $PANEL_SERVICE"
}
