#!/usr/bin/env bash
# ntopng: ntop.org apt repo, ntopng package, ntopng.conf rendered from
# NTOPNG_IFACES/NTOPNG_PORT (tech.md slice 5). Bound to 127.0.0.1 no
# matter what ACCESS_MODE says - real network exposure is slice 7's
# job, not this one's.

NTOPNG_PACKAGE="ntopng"
NTOPNG_UNIT="ntopng.service"
NTOP_REPO_DEB_URL_APT="https://packages.ntop.org/apt"

ntopng_effective_ifaces() {
	# criterion 2: NTOPNG_IFACES defaults to IFACES, an explicit value
	# (schema.sh default is empty) overrides it.
	local v="${CONF[NTOPNG_IFACES]:-}"
	if [[ -z "$v" ]]; then
		echo "${CONF[IFACES]:-}"
	else
		echo "$v"
	fi
}

ntopng_render_interfaces_block() {
	local ifaces
	ifaces=$(ntopng_effective_ifaces)
	local iface
	local IFS=','
	for iface in $ifaces; do
		[[ -z "$iface" ]] && continue
		echo "-i=${iface}"
	done
}

ntopng_render_conf() {
	render_template "$SCRIPT_DIR/templates/ntopng.conf.tpl" \
		"NTOPNG_INTERFACES=$(ntopng_render_interfaces_block)" \
		"NTOPNG_BIND=127.0.0.1:${CONF[NTOPNG_PORT]:-3000}" \
		"NTOPNG_PIDFILE=$(path_ntopng_pidfile)"
}

ntopng_repo_add() {
	# Real, documented ntop.org install sequence (packages.ntop.org):
	# add universe (Ubuntu only), fetch the tiny apt-ntop.deb that
	# registers the repo + imports the GPG key, then apt update.
	run add-apt-repository -y universe
	local version_id
	# shellcheck disable=SC1090
	version_id=$(. "$(os_release_file)" && echo "${VERSION_ID:-}")
	local deb_tmp
	deb_tmp="$(mktemp --suffix=.deb)"
	run wget -qO "$deb_tmp" "${NTOP_REPO_DEB_URL_APT}/${version_id}/all/apt-ntop.deb"
	run apt-get install -y "$deb_tmp"
	rm -f "$deb_tmp"
	run apt-get update
}

step_ntopng_check() {
	command -v ntopng >/dev/null 2>&1 || return 1

	local conf_path
	conf_path=$(path_ntopng_conf)
	[[ -f "$conf_path" ]] || return 1
	local expected_hash actual_hash
	expected_hash=$(ntopng_render_conf | state_hash_content)
	actual_hash=$(state_hash_content <"$conf_path")
	[[ "$expected_hash" == "$actual_hash" ]] || return 1

	systemctl is-active --quiet "$NTOPNG_UNIT" || return 1
	return 0
}

step_ntopng_apply() {
	if ! command -v ntopng >/dev/null 2>&1; then
		ntopng_repo_add
		pkg_install "$NTOPNG_PACKAGE"
	fi

	write_rendered_file "$(path_ntopng_conf)" "$(ntopng_render_conf)"

	run systemctl enable --now "$NTOPNG_UNIT"

	# criterion 3 (A4): bound to 127.0.0.1 in this slice regardless of
	# ACCESS_MODE, so the only safe thing to do about the default
	# admin/admin credential is to say so loudly - there is no
	# dpistack.conf key yet to set a real password from here.
	echo "ntopng: слушает только на 127.0.0.1:${CONF[NTOPNG_PORT]:-3000}, логин/пароль по умолчанию admin/admin - смените его в веб-интерфейсе перед тем, как открывать доступ шире (слайс 7)." >&2

	return 0
}

step_ntopng_plan() {
	echo "ntopng: интерфейсы $(ntopng_effective_ifaces), порт ${CONF[NTOPNG_PORT]:-3000} (только 127.0.0.1)"
	echo "ntopng: рендер $(path_ntopng_conf)"
}
