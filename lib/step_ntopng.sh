#!/usr/bin/env bash
# ntopng: ntop.org apt repo, ntopng package, ntopng.conf rendered from
# NTOPNG_IFACES/NTOPNG_PORT. Bind address comes from
# access_effective_bind_host (lib/step_access.sh, slice 7): 127.0.0.1
# for localhost/nginx modes, 0.0.0.0 for lan.

NTOPNG_PACKAGE="ntopng"
NTOPNG_UNIT="ntopng.service"
# The stable channel (apt-stable). "apt" next to it is the development one:
# nightly builds of the master branch, not for a security tool.
NTOP_REPO_DEB_URL_APT="https://packages.ntop.org/apt-stable"
NTOP_REPO_RPM_URL="https://packages.ntop.org/centos-stable/ntop.repo"

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
		"NTOPNG_BIND=$(access_effective_bind_host):$(access_backend_port "${CONF[NTOPNG_PORT]:-3000}")" \
		"NTOPNG_PIDFILE=$(path_ntopng_pidfile)"
}

# ntop.org publishes one rpm repo for the RHEL clones (EPEL comes from
# pkg_enable_extra_repos). Fedora and Amazon Linux are not in its list:
# there ntopng has to come from the distribution itself.
ntopng_repo_add_rpm() {
	case "$OS_ID" in
	rocky | almalinux | centos | rhel | ol)
		run curl -fsSL "$NTOP_REPO_RPM_URL" -o "$(path_ntop_repo_file)" || return 1
		run dnf -y makecache || return 1
		;;
	*)
		pkg_available "$NTOPNG_PACKAGE" || {
			echo "ntopng: ntop.org не публикует репозиторий для $OS_ID и в репозиториях дистрибутива пакета нет; шаг можно пропустить: --skip ntopng" >&2
			return 1
		}
		;;
	esac
}

ntopng_repo_add() {
	if [[ "$OS_FAMILY" == "dnf" ]]; then
		ntopng_repo_add_rpm
		return
	fi
	# Real, documented ntop.org install sequence (packages.ntop.org):
	# add universe (Ubuntu only), fetch the tiny apt-ntop.deb that
	# registers the repo + imports the GPG key, then apt update.
	# Debian has no universe component, only Ubuntu does.
	if [[ "$OS_ID" == "ubuntu" ]]; then
		run add-apt-repository -y universe || return 1
	else
		# ntop.org: on Debian add "contrib" to every deb and deb-src line.
		apt_enable_component contrib
	fi
	# ntop.org names the Ubuntu repos by version (apt/24.04) and the
	# Debian ones by release name (apt/bookworm); apt/12 does not exist.
	local version_id
	# shellcheck disable=SC1090
	if [[ "$OS_ID" == "ubuntu" ]]; then
		version_id=$(. "$(path_os_release)" && echo "${VERSION_ID:-}")
	else
		version_id=$(. "$(path_os_release)" && echo "${VERSION_CODENAME:-}")
	fi
	if [[ -z "$version_id" ]]; then
		log "ERROR" "ntopng: в os-release нет версии или имени релиза для репозитория ntop.org"
		return 1
	fi
	local deb_tmp
	deb_tmp="$(mktemp --suffix=.deb)"
	if ! run wget -qO "$deb_tmp" "${NTOP_REPO_DEB_URL_APT}/${version_id}/all/apt-ntop-stable.deb" ||
		! run apt-get install -y "$deb_tmp"; then
		rm -f "$deb_tmp"
		return 1
	fi
	rm -f "$deb_tmp"
	run apt-get update || return 1
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
		ntopng_repo_add || return 1
		pkg_install "$(pkg_spec "$NTOPNG_PACKAGE" "${CONF[NTOPNG_VERSION]:-}")" || return 1
	fi

	write_rendered_file "$(path_ntopng_conf)" "$(ntopng_render_conf)"

	run systemctl enable --now "$NTOPNG_UNIT" || return 1

	# A4: there is no dpistack.conf key to set a real ntopng password
	# from here, so the default admin/admin credential is only ever
	# safe when access_effective_bind_host keeps this on 127.0.0.1;
	# step_access.sh prints its own louder warning for lan/nginx modes.
	echo "ntopng: логин/пароль по умолчанию admin/admin, слушает на $(access_effective_bind_host):$(access_backend_port "${CONF[NTOPNG_PORT]:-3000}") - смените пароль в веб-интерфейсе." >&2

	return 0
}

step_ntopng_plan() {
	echo "ntopng: интерфейсы $(ntopng_effective_ifaces), порт ${CONF[NTOPNG_PORT]:-3000} (сервис на $(access_backend_port "${CONF[NTOPNG_PORT]:-3000}")), bind $(access_effective_bind_host)"
	echo "ntopng: рендер $(path_ntopng_conf)"
}
