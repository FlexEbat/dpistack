#!/usr/bin/env bash
# nDPI: NDPI_SOURCE=pkg installs the distro's libndpi-dev, NDPI_SOURCE=source
# clones and builds ntop/nDPI from GitHub (tech.md slice 4).

NDPI_PACKAGE="libndpi-dev"
# The dnf name is set once the family is known (see os_detect).
NDPI_REPO_URL="https://github.com/ntop/nDPI.git"

# Empty NDPI_VERSION means the release the Suricata nDPI plugin builds
# against. Built for real: the plugin in Suricata master compiles with
# nDPI 4.12 and 4.14 only (4.10 and older lack its API, 5.0 and master
# changed it), so master is not a safe default.
NDPI_COMPAT_REF="4.14"

ndpi_target_ref() {
	echo "${CONF[NDPI_VERSION]:-$NDPI_COMPAT_REF}"
}

ndpi_built_ref_state_key() { echo "ndpi.built_ref"; }

ndpi_pkg_installed_version() {
	pkg_installed_version "$NDPI_PACKAGE"
}

ndpi_source_lib_present() {
	[[ -f "$(path_ndpi_lib_dir)/libndpi.so" || -f "$(path_ndpi_lib_dir)/libndpi.a" ]]
}

step_ndpi_check() {
	[[ "${CONF[NDPI_ENABLE]:-no}" == "yes" ]] || return 0

	case "${CONF[NDPI_SOURCE]:-source}" in
	pkg)
		[[ -n "$(ndpi_pkg_installed_version)" ]]
		;;
	source)
		ndpi_source_lib_present || return 1
		local wanted have
		wanted=$(git_ref_commit "$(path_ndpi_src_dir)" "$(ndpi_target_ref)")
		have=$(state_read_value "$(ndpi_built_ref_state_key)")
		[[ -n "$wanted" && "$wanted" == "$have" ]]
		;;
	*)
		return 1
		;;
	esac
}

# ndpi_resolve_source - NDPI_SOURCE=pkg without a libndpi-dev candidate
# switches this run to a source build. Returns 0 when it changed the value.
ndpi_resolve_source() {
	[[ "${CONF[NDPI_ENABLE]:-no}" == "yes" && "${CONF[NDPI_SOURCE]:-source}" == "pkg" ]] || return 1
	[[ -z "$(ndpi_pkg_installed_version)" ]] || return 1
	pkg_available "$NDPI_PACKAGE" && return 1
	echo "ndpi: пакета $NDPI_PACKAGE нет в репозиториях, NDPI_SOURCE=pkg заменён на source (сборка из исходников)" >&2
	CONF[NDPI_SOURCE]=source
}

ndpi_build_from_source() {
	local src_dir ref
	src_dir=$(path_ndpi_src_dir)
	pkg_build_deps ndpi || return 1
	ref=$(ndpi_target_ref)

	if [[ ! -d "$src_dir/.git" ]]; then
		run git clone "$NDPI_REPO_URL" "$src_dir" || return 1
	else
		run git -C "$src_dir" fetch --tags origin || return 1
	fi

	run git -C "$src_dir" checkout "$ref" || return 1

	local resolved_ref
	resolved_ref=$(git -C "$src_dir" rev-parse HEAD 2>/dev/null)

	(
		cd "$src_dir" || exit 1
		run ./autogen.sh &&
			run ./configure --prefix=/usr/local &&
			run make -j"$(nproc)" &&
			run make install
	)
	local rc=$?
	if [[ "$rc" -ne 0 ]]; then
		echo "nDPI: сборка из исходников упала (autogen/configure/make), см. вывод выше" >&2
		return 1
	fi

	[[ "${DRY_RUN:-0}" != "1" ]] && run ldconfig
	[[ -n "$resolved_ref" ]] && state_write_value "$(ndpi_built_ref_state_key)" "$resolved_ref"
	return 0
}

step_ndpi_apply() {
	if [[ "${CONF[NDPI_ENABLE]:-no}" != "yes" ]]; then
		return 0
	fi

	case "${CONF[NDPI_SOURCE]:-source}" in
	pkg)
		pkg_install "$NDPI_PACKAGE" || return 1
		;;
	source)
		ndpi_build_from_source
		;;
	*)
		echo "NDPI_SOURCE=${CONF[NDPI_SOURCE]}: неизвестный источник" >&2
		return 1
		;;
	esac
}

step_ndpi_plan() {
	if [[ "${CONF[NDPI_ENABLE]:-no}" != "yes" ]]; then
		echo "ndpi: NDPI_ENABLE=no, без изменений"
		return 0
	fi
	case "${CONF[NDPI_SOURCE]:-source}" in
	pkg) echo "ndpi: установка пакета $NDPI_PACKAGE" ;;
	source) echo "ndpi: сборка из исходников ($NDPI_REPO_URL, ref=$(ndpi_target_ref | sed 's/^$/HEAD/'))" ;;
	esac
}
