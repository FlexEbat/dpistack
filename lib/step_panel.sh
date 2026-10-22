#!/usr/bin/env bash
# "panel" step: the system user `dpistack`, the sudoers rule that lets it
# run only dpistack (tech.md 4.2, 4.5), the panel binary (PANEL_SOURCE:
# built from panel/ with Go, or a ready dpistack-panel next to install.sh)
# and the systemd unit with the resource budget (tech.md 9).

PANEL_USER="dpistack"
PANEL_SERVICE="dpistack-panel.service"
PANEL_SRC_HASH_KEY="panel.src_hash"

# panel_prebuilt_path - the ready binary next to install.sh: the one for
# this CPU (dpistack-panel-linux-amd64 or -arm64, as the release archive
# ships them), else a plain dpistack-panel. When neither exists it names
# the file a release archive would have, for messages.
panel_prebuilt_path() {
	local arch f
	case "$(uname -m)" in
	x86_64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) arch=$(uname -m) ;;
	esac
	for f in "$ORIGIN_DIR/dpistack-panel-linux-$arch" "$ORIGIN_DIR/dpistack-panel"; do
		if [[ -f "$f" ]]; then
			echo "$f"
			return 0
		fi
	done
	echo "$ORIGIN_DIR/dpistack-panel-linux-$arch"
}

# panel_source_mode - build or prebuilt. auto (the default) takes the ready
# binary when one lies next to install.sh, as in a release archive, and
# builds from panel/ otherwise, as in a git checkout.
panel_source_mode() {
	case "${CONF[PANEL_SOURCE]:-auto}" in
	auto)
		if [[ -f "$(panel_prebuilt_path)" ]]; then
			echo prebuilt
		else
			echo build
		fi
		;;
	*) echo "${CONF[PANEL_SOURCE]}" ;;
	esac
}

# panel_src_hash - one hash over everything the binary is built from, so
# a changed source or web file rebuilds it and an unchanged one does not.
panel_src_hash() {
	[[ -d "$ORIGIN_DIR/panel" ]] || return 1
	(cd "$ORIGIN_DIR/panel" &&
		find . -type f \( -name '*.go' -o -name go.mod -o -name go.sum -o -path './web/*' \) -print0 |
		sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

# panel_token_wanted - 0 when GET /metrics is on and there is a token to guard
# it. The token reaches the panel through a file: a flag would show in ps
# and in the unit.
panel_token_wanted() {
	[[ "${CONF[METRICS_EXPORT]:-yes}" == "yes" && -n "${SECRETS[METRICS_TOKEN]:-}" ]]
}

# panel_token_matches - the token file holds the current token when /metrics
# is on, and does not exist when it is off.
panel_token_matches() {
	local file
	file=$(path_metrics_token)
	if panel_token_wanted; then
		[[ -f "$file" && "$(<"$file")" == "${SECRETS[METRICS_TOKEN]}" ]]
	else
		[[ ! -e "$file" ]]
	fi
}

# panel_args - the flags of the panel (tech.md 9). The panel does not read
# dpistack.conf, so LAN_CIDR=auto is resolved here.
panel_args() {
	local mode="${CONF[ACCESS_MODE]:-localhost}" port
	port=$(access_backend_port "${CONF[PANEL_PORT]:-9800}")
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
	args+=" -auth-file $(path_panel_auth) -health-file $(path_health_json) -ctl $(path_ctl_bin) -metrics-file $(path_metrics_json)"
	# Without the flag the panel shows that viewing events is off.
	[[ "${CONF[EVE_FILE]:-yes}" == "yes" ]] && args+=" -eve-file $(path_suricata_eve_json)"
	# The Tests and Alerts screens read these two files whatever /metrics does.
	args+=" -tests-file $(path_tests_last_json) -events-file $(path_events_jsonl)"
	# Without a token file /metrics does not exist (404).
	if panel_token_wanted; then
		local disks
		disks=$(dirname "$(path_suricata_eve_json)")
		[[ "${CONF[EVEBOX_DB]:-sqlite}" == "sqlite" ]] && disks+=",$(path_evebox_data_dir)"
		args+=" -metrics-token-file $(path_metrics_token) -rules-file $(path_suricata_ruleset) -disk-paths ${disks}"
	fi
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
		# Run from the installed copy (dpistack reconfigure) there is no
		# ready binary next to the script any more: what is installed stays.
		[[ -f "$(panel_prebuilt_path)" ]] || return 0
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
	if ! (cd "$ORIGIN_DIR/panel" &&
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

	[[ -f "$(path_metrics_json)" ]] || return 1
	panel_token_matches || return 1
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

	# The panel keeps its graph history in metrics.json and may write nothing
	# else in the state directory (health.json, state and the backups stay
	# root's), so only this one file is its own. An existing history is kept.
	local mfile
	mfile=$(path_metrics_json)
	if [[ ! -e "$mfile" ]]; then
		run install -D -m 0640 /dev/null "$mfile" || return 1
	fi
	run chown "$PANEL_USER:$PANEL_USER" "$mfile" || return 1

	# The bearer token of /metrics: readable by the panel, nobody else. In a
	# dry run only the fact is printed, never the value.
	local tfile
	tfile=$(path_metrics_token)
	if panel_token_wanted; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			echo "+ записать $tfile (0640 root:$PANEL_USER)"
		else
			printf '%s\n' "${SECRETS[METRICS_TOKEN]}" | atomic_write "$tfile" 0640 || return 1
			run chown "root:$PANEL_USER" "$tfile" || return 1
		fi
	else
		run rm -f "$tfile" || return 1
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
	echo "panel: пользователь $PANEL_USER, sudoers $(path_sudoers) (только dpistack), бинарник $(path_panel_bin) (PANEL_SOURCE=$(panel_source_mode)), юнит $PANEL_SERVICE"
}

# panel_report_metrics - the token of /metrics and a scrape_config entry
# ready to paste, printed once when the token has just been made. Never in a
# dry run: the token does not exist then.
panel_report_metrics() {
	[[ "${METRICS_TOKEN_JUST_GENERATED:-0}" == "1" && "${DRY_RUN:-0}" != "1" ]] || return 0
	panel_token_wanted || return 0
	local mode="${CONF[ACCESS_MODE]:-localhost}" port="${CONF[PANEL_PORT]:-9800}" scheme="http" host="127.0.0.1"
	if [[ "$mode" != "localhost" ]]; then
		host="<адрес-сервера>"
	fi
	[[ "$mode" == "nginx" && "${CONF[NGINX_TLS]:-none}" != "none" ]] && scheme="https"
	echo "Создан METRICS_TOKEN для GET /metrics (сохраните: он больше нигде не показывается): ${SECRETS[METRICS_TOKEN]}"
	echo "Строка для scrape_configs (Prometheus и VictoriaMetrics):"
	cat <<EOF
  - job_name: dpistack
    metrics_path: /metrics
    scheme: ${scheme}
    authorization:
      type: Bearer
      credentials: ${SECRETS[METRICS_TOKEN]}
    static_configs:
      - targets: ['${host}:${port}']
EOF
}
