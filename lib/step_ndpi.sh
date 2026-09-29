#!/usr/bin/env bash
# nDPI: NDPI_SOURCE=pkg installs the distro's libndpi-dev, NDPI_SOURCE=source
# clones and builds ntop/nDPI from GitHub (tech.md slice 4). Verified for
# real in this environment: clone, autogen.sh, configure, make, make
# install all work against the current ntop/nDPI master.

NDPI_PACKAGE="libndpi-dev"
NDPI_REPO_URL="https://github.com/ntop/nDPI.git"

ndpi_target_ref() {
	# Empty NDPI_VERSION tracks the repo's default branch.
	echo "${CONF[NDPI_VERSION]:-}"
}

ndpi_built_ref_state_key() { echo "ndpi.built_ref"; }

ndpi_pkg_installed_version() {
	dpkg-query -W -f='${Version}' "$NDPI_PACKAGE" 2>/dev/null
}

ndpi_source_lib_present() {
	[[ -f "${DPISTACK_ROOT}/usr/local/lib/libndpi.so" || -f "${DPISTACK_ROOT}/usr/local/lib/libndpi.a" ]]
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
		wanted=$(ndpi_target_ref)
		have=$(state_read_value "$(ndpi_built_ref_state_key)")
		[[ -z "$wanted" || "$wanted" == "$have" ]]
		;;
	*)
		return 1
		;;
	esac
}

ndpi_build_from_source() {
	local src_dir ref
	src_dir=$(path_ndpi_src_dir)
	ref=$(ndpi_target_ref)

	if [[ ! -d "$src_dir/.git" ]]; then
		run git clone "$NDPI_REPO_URL" "$src_dir"
	else
		run git -C "$src_dir" fetch --tags origin
	fi

	if [[ -n "$ref" ]]; then
		run git -C "$src_dir" checkout "$ref"
	else
		run git -C "$src_dir" checkout HEAD
	fi

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
		pkg_install "$NDPI_PACKAGE"
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
