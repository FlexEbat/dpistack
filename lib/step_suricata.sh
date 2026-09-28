#!/usr/bin/env bash
# Suricata IDS: package install from distro/oisf, suricata.yaml and
# logrotate rendering, systemd unit (tech.md slice 2). Source builds
# and nDPI are schema.sh "пока не поддерживается" until slice 4.

SURICATA_PACKAGE="suricata"
SURICATA_UNIT="suricata.service"

suricata_home_net_value() {
	local v="${CONF[HOME_NET]:-}"
	if [[ -z "$v" || "$v" == "auto" ]]; then
		echo '[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]'
	else
		echo "$v"
	fi
}

suricata_render_af_packet_block() {
	local ifaces="${CONF[IFACES]:-}"
	local bpf="${CONF[BPF_FILTER]:-}"
	local iface cluster_id=99
	local IFS=','
	for iface in $ifaces; do
		[[ -z "$iface" ]] && continue
		echo "  - interface: ${iface}"
		echo "    cluster-id: ${cluster_id}"
		echo "    cluster-type: cluster_flow"
		echo "    defrag: yes"
		[[ -n "$bpf" ]] && echo "    bpf-filter: \"${bpf}\""
		cluster_id=$((cluster_id + 1))
	done
	echo "  - interface: default"
}

suricata_render_eve_types_block() {
	local types="${CONF[EVE_TYPES]:-alert,flow}"
	local t
	local IFS=','
	echo "      types:"
	for t in $types; do
		[[ -z "$t" ]] && continue
		echo "        - ${t}"
	done
}

suricata_render_plugins_block() {
	if [[ "${CONF[NDPI_ENABLE]:-no}" == "yes" ]]; then
		echo "  - $(path_suricata_ndpi_plugin)"
	fi
}

suricata_render_eve_log_block() {
	echo "  - eve-log:"
	echo "      enabled: yes"
	echo "      filetype: regular"
	echo "      filename: eve.json"
	echo "      pcap-file: false"
	echo "      community-id: false"
	echo "      community-id-seed: 0"
	echo "      xff:"
	echo "        enabled: no"
	echo "        mode: extra-data"
	echo "        deployment: reverse"
	echo "        header: X-Forwarded-For"
	suricata_render_eve_types_block
}

# suricata_render_yaml -> full suricata.yaml on stdout
suricata_render_yaml() {
	render_template "$SCRIPT_DIR/templates/suricata.yaml.tpl" \
		"HOME_NET=$(suricata_home_net_value)" \
		"STATS_INTERVAL=${CONF[STATS_INTERVAL_SEC]:-30}" \
		"EVE_LOG_BLOCK=$(suricata_render_eve_log_block)" \
		"AF_PACKET_BLOCK=$(suricata_render_af_packet_block)" \
		"PLUGINS_BLOCK=$(suricata_render_plugins_block)"
}

suricata_rotate_directive() {
	case "${CONF[EVE_ROTATE]:-daily}" in
	weekly) echo "weekly" ;;
	size) echo "size ${CONF[EVE_MAX_SIZE_MB]:-100}M" ;;
	*) echo "daily" ;;
	esac
}

# suricata_render_logrotate -> full logrotate stanza on stdout
suricata_render_logrotate() {
	render_template "$SCRIPT_DIR/templates/logrotate.tpl" \
		"EVE_JSON_PATH=$(path_suricata_eve_json)" \
		"ROTATE_DIRECTIVE=$(suricata_rotate_directive)" \
		"EVE_KEEP=${CONF[EVE_KEEP]:-14}"
}

suricata_installed_version() {
	dpkg-query -W -f='${Version}' "$SURICATA_PACKAGE" 2>/dev/null
}

SURICATA_REPO_URL="https://github.com/OISF/suricata.git"
SURICATA_BUILT_REF_STATE_KEY="suricata.built_ref"

suricata_source_binary_present() {
	command -v suricata >/dev/null 2>&1 && [[ "$(command -v suricata)" == "${DPISTACK_ROOT}/usr/local/bin/suricata" ]]
}

suricata_build_from_source() {
	local src_dir ref
	src_dir=$(path_suricata_src_dir)
	ref="${CONF[SURICATA_VERSION]:-}"

	if [[ ! -d "$src_dir/.git" ]]; then
		run git clone "$SURICATA_REPO_URL" "$src_dir"
		run git -C "$src_dir" submodule update --init --recursive
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

	local configure_args=(--prefix=/usr/local --sysconfdir="${DPISTACK_ROOT}/etc"
		--localstatedir="${DPISTACK_ROOT}/var" --disable-gccmarch-native)
	if [[ "${CONF[NDPI_ENABLE]:-no}" == "yes" ]]; then
		configure_args+=(--enable-ndpi --with-ndpi="$(path_ndpi_src_dir)")
	fi

	(
		cd "$src_dir" || exit 1
		run ./autogen.sh &&
			run ./configure "${configure_args[@]}" &&
			run make -j"$(nproc)" &&
			run make install
	)
	local rc=$?
	if [[ "$rc" -ne 0 ]]; then
		echo "suricata: сборка из исходников упала (autogen/configure/make)" >&2
		return 1
	fi

	[[ "${DRY_RUN:-0}" != "1" ]] && run ldconfig
	[[ -n "$resolved_ref" ]] && state_write_value "$SURICATA_BUILT_REF_STATE_KEY" "$resolved_ref"
	return 0
}

suricata_render_service_unit() {
	render_template "$SCRIPT_DIR/templates/suricata.service.tpl" \
		"RUNDIR=${DPISTACK_ROOT}/run/" \
		"SYSCONFDIR=${DPISTACK_ROOT}/etc/suricata/"
}

step_suricata_check() {
	local source="${CONF[SURICATA_SOURCE]:-}"
	[[ "$source" =~ ^(distro|oisf|source)$ ]] || return 1

	if [[ "$source" == "source" ]]; then
		suricata_source_binary_present || return 1
		local wanted have
		wanted="${CONF[SURICATA_VERSION]:-}"
		have=$(state_read_value "$SURICATA_BUILT_REF_STATE_KEY")
		[[ -z "$wanted" || "$wanted" == "$have" ]] || return 1
	else
		command -v suricata >/dev/null 2>&1 || return 1
		[[ -n "$(suricata_installed_version)" ]] || return 1
	fi

	local yaml_path logrotate_path
	yaml_path=$(path_suricata_yaml)
	logrotate_path=$(path_suricata_logrotate)

	[[ -f "$yaml_path" ]] || return 1
	local expected_yaml_hash actual_yaml_hash
	expected_yaml_hash=$(suricata_render_yaml | state_hash_content)
	actual_yaml_hash=$(state_hash_content <"$yaml_path")
	[[ "$expected_yaml_hash" == "$actual_yaml_hash" ]] || return 1

	[[ -f "$logrotate_path" ]] || return 1
	local expected_lr_hash actual_lr_hash
	expected_lr_hash=$(suricata_render_logrotate | state_hash_content)
	actual_lr_hash=$(state_hash_content <"$logrotate_path")
	[[ "$expected_lr_hash" == "$actual_lr_hash" ]] || return 1

	if [[ "$source" == "source" ]]; then
		local service_path
		service_path=$(path_suricata_service_unit)
		[[ -f "$service_path" ]] || return 1
		local expected_svc_hash actual_svc_hash
		expected_svc_hash=$(suricata_render_service_unit | state_hash_content)
		actual_svc_hash=$(state_hash_content <"$service_path")
		[[ "$expected_svc_hash" == "$actual_svc_hash" ]] || return 1
	fi

	systemctl is-active --quiet "$SURICATA_UNIT" || return 1

	return 0
}

step_suricata_apply() {
	case "${CONF[SURICATA_SOURCE]}" in
	oisf)
		pkg_repo_add oisf
		if ! command -v suricata >/dev/null 2>&1 || [[ -z "$(suricata_installed_version)" ]]; then
			pkg_install "$SURICATA_PACKAGE"
		fi
		;;
	distro)
		if ! command -v suricata >/dev/null 2>&1 || [[ -z "$(suricata_installed_version)" ]]; then
			pkg_install "$SURICATA_PACKAGE"
		fi
		;;
	source)
		suricata_build_from_source || return 1
		;;
	esac

	local yaml_path logrotate_path
	yaml_path=$(path_suricata_yaml)
	logrotate_path=$(path_suricata_logrotate)

	write_rendered_file "$yaml_path" "$(suricata_render_yaml)"
	write_rendered_file "$logrotate_path" "$(suricata_render_logrotate)"

	if [[ "${CONF[SURICATA_SOURCE]}" == "source" ]]; then
		write_rendered_file "$(path_suricata_service_unit)" "$(suricata_render_service_unit)"
		run systemctl daemon-reload
	fi

	run systemctl enable --now "$SURICATA_UNIT"
	local eve_json
	eve_json=$(path_suricata_eve_json)
	[[ -f "$eve_json" ]] && run chmod 0640 "$eve_json"

	if [[ "${CONF[PIN_VERSIONS]:-no}" == "yes" && "${CONF[SURICATA_SOURCE]}" != "source" ]]; then
		pkg_pin "$SURICATA_PACKAGE"
	fi

	return 0
}

step_suricata_plan() {
	if [[ "${CONF[SURICATA_SOURCE]:-}" == "source" ]]; then
		echo "suricata: сборка из исходников ($SURICATA_REPO_URL, ref=${CONF[SURICATA_VERSION]:-HEAD}, nDPI=${CONF[NDPI_ENABLE]:-no})"
	else
		echo "suricata: установка/обновление пакета ($OS_FAMILY, источник ${CONF[SURICATA_SOURCE]:-distro})"
	fi
	echo "suricata: рендер $(path_suricata_yaml) для интерфейсов ${CONF[IFACES]:-}"
	echo "suricata: рендер $(path_suricata_logrotate)"
	echo "suricata: systemctl enable --now $SURICATA_UNIT"
}
