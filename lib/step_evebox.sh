#!/usr/bin/env bash
# EveBox: official apt repo (evebox.org/docs/install/debian), package,
# evebox.yaml from templates/evebox.yaml.tpl (tech.md slice 6). Bound to
# 127.0.0.1 until slice 7. The package ships the evebox.service unit and
# EveBox's built-in database.retention.days handles retention (A9,
# SQLite only; 0 disables).

EVEBOX_PACKAGE="evebox"
EVEBOX_UNIT="evebox.service"
EVEBOX_KEY_URL="https://evebox.org/files/evebox.asc"
EVEBOX_REPO_URL="https://evebox.org/files/debian"

evebox_render_es_block() {
	if [[ "${CONF[EVEBOX_DB]:-sqlite}" == "elasticsearch" ]]; then
		echo "  elasticsearch:"
		echo "    url: ${CONF[EVEBOX_ES_URL]:-}"
	fi
}

evebox_render_input_paths() {
	local eve_json
	eve_json=$(path_suricata_eve_json)
	echo "    - \"${eve_json}\""
	echo "    - \"$(dirname "$eve_json")/eve.*.json\""
}

evebox_input_enabled() {
	# The server reads eve.json itself for both databases (SQLite, or
	# shipping into Elasticsearch); without EVE_FILE there is no file.
	if [[ "${CONF[EVE_FILE]:-yes}" == "yes" ]]; then
		echo "true"
	else
		echo "false"
	fi
}

evebox_render_conf() {
	render_template "$SCRIPT_DIR/templates/evebox.yaml.tpl" \
		"EVEBOX_HOST=127.0.0.1" \
		"EVEBOX_PORT=${CONF[EVEBOX_PORT]:-5636}" \
		"EVEBOX_DB_TYPE=${CONF[EVEBOX_DB]:-sqlite}" \
		"EVEBOX_RETENTION_DAYS=${CONF[EVEBOX_RETENTION_DAYS]:-30}" \
		"EVEBOX_INPUT_ENABLED=$(evebox_input_enabled)" \
		"EVEBOX_ES_BLOCK=$(evebox_render_es_block)" \
		"EVEBOX_INPUT_PATHS=$(evebox_render_input_paths)"
}

evebox_repo_add() {
	run mkdir -p "$(dirname "$(path_evebox_keyring)")"
	run curl -fsSL "$EVEBOX_KEY_URL" -o "$(path_evebox_keyring)"
	write_rendered_file "$(path_evebox_apt_list)" \
		"deb [signed-by=$(path_evebox_keyring)] ${EVEBOX_REPO_URL} stable main"
	run apt-get update
}

step_evebox_check() {
	command -v evebox >/dev/null 2>&1 || return 1

	local conf_path
	conf_path=$(path_evebox_yaml)
	[[ -f "$conf_path" ]] || return 1
	local expected_hash actual_hash
	expected_hash=$(evebox_render_conf | state_hash_content)
	actual_hash=$(state_hash_content <"$conf_path")
	[[ "$expected_hash" == "$actual_hash" ]] || return 1

	systemctl is-active --quiet "$EVEBOX_UNIT" || return 1
	return 0
}

step_evebox_apply() {
	if ! command -v evebox >/dev/null 2>&1; then
		evebox_repo_add
		pkg_install "$EVEBOX_PACKAGE"
	fi

	write_rendered_file "$(path_evebox_yaml)" "$(evebox_render_conf)"

	# The evebox user must read Suricata's logs (official Debian docs).
	if getent group suricata >/dev/null 2>&1; then
		run usermod -a -G suricata evebox
	fi

	run systemctl enable --now "$EVEBOX_UNIT"

	if [[ "${CONF[EVEBOX_DB]:-sqlite}" == "elasticsearch" ]]; then
		echo "evebox: EVEBOX_RETENTION_DAYS работает только с SQLite, для Elasticsearch удаление старых событий настраивается на стороне Elasticsearch." >&2
	fi
	echo "evebox: слушает только на 127.0.0.1:${CONF[EVEBOX_PORT]:-5636}; встроенные TLS и аутентификация EveBox отключены, доступ ограничивается сетью (слайс 7)." >&2
	return 0
}

step_evebox_plan() {
	echo "evebox: репозиторий evebox.org, пакет $EVEBOX_PACKAGE, база ${CONF[EVEBOX_DB]:-sqlite}, порт ${CONF[EVEBOX_PORT]:-5636} (только 127.0.0.1)"
	echo "evebox: рендер $(path_evebox_yaml)"
}
