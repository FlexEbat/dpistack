#!/usr/bin/env bash
# Real preflight (tech.md 5.5). Runs once, before any package gets
# installed; collects every failure reason instead of stopping at the
# first one (install.sh's cmd_install dies with all of them, code 3).

# preflight_step_wanted <step> - the step is part of this run (--skip and
# --only are honoured when the installer has parsed them).
preflight_step_wanted() {
	if declare -F step_selected >/dev/null 2>&1; then
		step_selected "$1"
	else
		return 0
	fi
}

# preflight_port_busy <port> - something already listens on the port.
preflight_port_busy() {
	ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${1}\$"
}

# preflight_port_owner <port> - the name of the process that listens on the
# port, empty when it cannot be seen (ss shows other users' sockets only to
# root, and the installer is root).
preflight_port_owner() {
	ss -ltnp 2>/dev/null | awk -v p=":${1}$" '$4 ~ p {print $NF}' |
		sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1
}

# PREFLIGHT_PORT_KEYS - every port key of dpistack.conf, with the step that
# owns it (the owner's check says whether the port is dpistack's own).
PREFLIGHT_PORT_KEYS=(NTOPNG_PORT:ntopng EVEBOX_PORT:evebox PANEL_PORT:panel METRICS_BACKEND_PORT:metrics)

# preflight_port_taken_by_conf <port> <skip-key> - another key of the
# configuration already uses this port, as a public port or, with nginx, as
# the port behind it.
preflight_port_taken_by_conf() {
	local port="$1" skip="$2" pair key value
	for pair in "${PREFLIGHT_PORT_KEYS[@]}"; do
		key="${pair%%:*}"
		[[ "$key" == "$skip" ]] && continue
		value="${CONF[$key]:-}"
		[[ -z "$value" ]] && continue
		[[ "$value" == "$port" ]] && return 0
		if [[ "$key" != "METRICS_BACKEND_PORT" && "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]] &&
			[[ "$(access_backend_port "$value")" == "$port" ]]; then
			return 0
		fi
	done
	return 1
}

# preflight_free_port <key> <from> - the first port from <from> upward that
# nothing listens on and no other key of the configuration uses. With nginx
# the port behind nginx (PORT+10000) has to be free too. Empty when none.
preflight_free_port() {
	local key="$1" candidate="$2" backend
	while ((candidate <= 65535)); do
		if ! preflight_port_busy "$candidate" && ! preflight_port_taken_by_conf "$candidate" "$key"; then
			if [[ "$key" != "METRICS_BACKEND_PORT" && "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
				backend=$(access_backend_port "$candidate")
				if ((backend <= 65535)) && ! preflight_port_busy "$backend" && ! preflight_port_taken_by_conf "$backend" "$key"; then
					echo "$candidate"
					return 0
				fi
			else
				echo "$candidate"
				return 0
			fi
		fi
		candidate=$((candidate + 1))
	done
	return 1
}

# preflight_port_conflicts - one line per busy port: KEY|port|who|suggestion.
# A port held by a service dpistack already installed is not a conflict on a
# repeat run, so ports whose step is already applied are skipped. With
# ACCESS_MODE=nginx both ports matter: nginx takes the public one (the
# access step owns it), the service takes public+10000.
preflight_port_conflicts() {
	local pair port_key owner_step public port who
	for pair in "${PREFLIGHT_PORT_KEYS[@]}"; do
		port_key="${pair%%:*}"
		owner_step="${pair#*:}"
		step_component_enabled "$owner_step" || continue
		public="${CONF[$port_key]:-}"
		[[ -z "$public" ]] && continue
		if [[ "$port_key" != "METRICS_BACKEND_PORT" && "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
			if ! step_access_check && preflight_port_busy "$public"; then
				who=$(preflight_port_owner "$public")
				echo "$port_key|$public|${who:-unknown process}|$(preflight_free_port "$port_key" "$((public + 1))")|nginx"
			fi
			port=$(access_backend_port "$public")
		else
			port="$public"
		fi
		if "step_${owner_step}_check"; then
			continue
		fi
		if preflight_port_busy "$port"; then
			who=$(preflight_port_owner "$port")
			echo "$port_key|$port|${who:-unknown process}|$(preflight_free_port "$port_key" "$((public + 1))")|service"
		fi
	done
}

# preflight_resolve_ports_interactive - for every busy port: a warning with
# the name of the process that holds it and the question which port to use
# instead (Enter takes the suggested free one, "q" leaves the port as it is
# and the preflight will stop on it). Reads through the menu's input, so it
# runs inside the menu. Returns 0 when no conflicts remain unanswered.
preflight_resolve_ports_interactive() {
	local line key port who suggestion kind answer rc=0
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		IFS='|' read -r key port who suggestion kind <<<"$line"
		echo >&2
		echo "  WARNING: port $port ($key) is already busy: $who" >&2
		while true; do
			menu_read answer "  Another port for $key [${suggestion:-none free}] (q: keep): "
			menu_die_on_eof
			[[ -z "$answer" ]] && answer="$suggestion"
			if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
				rc=1
				break
			fi
			if [[ ! "$answer" =~ ^[0-9]+$ ]] || ((10#$answer < 1 || 10#$answer > 65535)); then
				echo "  a number from 1 to 65535 is needed" >&2
				continue
			fi
			answer=$((10#$answer))
			if preflight_port_busy "$answer" || preflight_port_taken_by_conf "$answer" "$key"; then
				echo "  port $answer is busy too, choose another" >&2
				continue
			fi
			if [[ "$kind" == "nginx" || "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]] && [[ "$key" != "METRICS_BACKEND_PORT" ]]; then
				local behind
				behind=$(access_backend_port "$answer")
				if ((behind > 65535)) || preflight_port_busy "$behind" || preflight_port_taken_by_conf "$behind" "$key"; then
					echo "  with nginx in front it also needs port $behind, which is unavailable; choose another" >&2
					continue
				fi
			fi
			CONF["$key"]="$answer"
			echo "  $key = $answer" >&2
			# shellcheck disable=SC2034 # read by lib/menu.sh
			MENU_DIRTY=1
			break
		done
	done < <(preflight_port_conflicts)
	return "$rc"
}

# preflight_panel_reasons - the panel binary has to be obtainable before
# the install starts: a ready file for prebuilt, Go (at least the version
# panel/go.mod asks for) for build. A binary that is already installed and
# current needs neither, so a repeat run on a host without Go still passes.
preflight_panel_reasons() {
	panel_bin_current && return 0
	if [[ "$(panel_source_mode)" == "prebuilt" ]]; then
		if [[ ! -f "$(panel_prebuilt_path)" ]]; then
			reasons+=("PANEL_SOURCE=prebuilt, but there is no ready dpistack-panel binary next to install.sh (in the release archive it is called $(basename "$(panel_prebuilt_path)"))")
		fi
		return 0
	fi
	if [[ ! -d "$ORIGIN_DIR/panel" ]]; then
		reasons+=("cannot get the panel: next to install.sh there is neither a ready binary ($(basename "$(panel_prebuilt_path)")), nor a panel/ directory with the sources")
		return 0
	fi
	local need
	need=$(panel_go_required)
	# A Go that is not on the host is no reason to stop when Docker can build
	# the panel in a Go image (step_panel.sh, panel_build_in_container).
	panel_host_go_ok && return 0
	panel_can_build_in_container && return 0
	if ! command -v go >/dev/null 2>&1; then
		reasons+=("cannot get the panel: there is no Go (Go ${need:-newer} is needed), no Docker to build it in a container, and no ready binary next to install.sh ($(basename "$(panel_prebuilt_path)"))")
	else
		reasons+=("cannot get the panel: Go $(go version | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p') is older than the required $need, there is no Docker to build it in a container and no ready binary next to install.sh ($(basename "$(panel_prebuilt_path)"))")
	fi
}

step_preflight_reasons() {
	local reasons=()

	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		reasons+=("root rights are needed")
	fi

	if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
		reasons+=("Bash 4.4+ is needed, now ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}")
	fi

	if ! command -v systemctl >/dev/null 2>&1; then
		reasons+=("systemd (systemctl) not found, needed for the native runtime")
	fi

	if preflight_step_wanted panel; then
		preflight_panel_reasons
	fi

	local key
	for key in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME METRICS_BACKEND_RUNTIME PANEL_RUNTIME; do
		if [[ "${CONF[$key]:-}" == "docker" ]] && ! command -v docker >/dev/null 2>&1; then
			reasons+=("$key=docker, but docker was not found")
		fi
	done

	# Outside apt and dnf there are no packages of the project's components:
	# they run in Docker, and the reason says which keys to set.
	if [[ "$OS_FAMILY" != "apt" && "$OS_FAMILY" != "dnf" ]]; then
		local nkey
		for nkey in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME; do
			if [[ "${CONF[$nkey]:-native}" == "native" ]]; then
				reasons+=("$nkey=native: on $OS_ID the installer does not install the component packages, set --set $nkey=docker")
			fi
		done
		if [[ "${CONF[METRICS_BACKEND]:-none}" != "none" && "${CONF[METRICS_BACKEND_RUNTIME]:-native}" == "native" ]]; then
			reasons+=("METRICS_BACKEND_RUNTIME=native: on $OS_ID set --set METRICS_BACKEND_RUNTIME=docker")
		fi
		if [[ "${CONF[NDPI_ENABLE]:-no}" == "yes" ]]; then
			reasons+=("NDPI_ENABLE=yes: the nDPI plugin needs a Suricata built on the host; on $OS_ID set --set NDPI_ENABLE=no")
		fi
	fi
	if [[ "${CONF[SURICATA_MODE]:-ids}" == "ips" && "${CONF[IPS_METHOD]:-nfq}" == "nfq" ]] && [[ -z "$(ips_backend)" ]]; then
		reasons+=("SURICATA_MODE=ips with IPS_METHOD=nfq: neither iptables nor nft found (needed for the NFQUEUE queue)")
	fi
	if [[ "${CONF[SURICATA_RUNTIME]:-native}" == "docker" && "${CONF[NDPI_ENABLE]:-no}" == "yes" ]]; then
		reasons+=("SURICATA_RUNTIME=docker: the nDPI plugin is not installed into the image, set NDPI_ENABLE=no")
	fi
	if command -v docker >/dev/null 2>&1; then
		local dkey
		for dkey in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME PANEL_RUNTIME; do
			if [[ "${CONF[$dkey]:-}" == "docker" ]] && ! docker compose version >/dev/null 2>&1; then
				reasons+=("$dkey=docker, but docker has no compose plugin (docker compose version does not answer)")
				break
			fi
		done
	fi

	case "$(os_support_level)" in
	unsupported)
		if [[ "${DPISTACK_ALLOW_UNSUPPORTED:-0}" != "1" ]]; then
			reasons+=("$OS_ID ${OS_VERSION_ID:-} is not supported (supported: Ubuntu LTS from 22.04, Debian from 12, Rocky Linux and AlmaLinux from 8); to go on at your own risk: DPISTACK_ALLOW_UNSUPPORTED=1")
		fi
		;;
	unverified)
		log "WARN" "$OS_ID ${OS_VERSION_ID:-} is not in the list of tested platforms (tech.md 11), the installation goes on"
		;;
	esac

	local iface _preflight_ifaces
	IFS=',' read -ra _preflight_ifaces <<<"${CONF[IFACES]:-}"
	for iface in "${_preflight_ifaces[@]}"; do
		[[ -z "$iface" ]] && continue
		if ! net_iface_exists "$iface"; then
			reasons+=("interface $iface from IFACES does not exist")
		fi
	done

	local bind_addr="${CONF[BIND_ADDR]:-auto}"
	if [[ "$bind_addr" != "auto" && "${CONF[ACCESS_MODE]:-localhost}" != "nginx" ]] && [[ "$bind_addr" != 127.* ]]; then
		if ! access_local_addresses | awk -v a="$bind_addr" '$2 == a {found = 1} END {exit !found}'; then
			reasons+=("BIND_ADDR=$bind_addr is not an address of this host")
		fi
	fi

	local need_gb=1
	[[ "${CONF[SURICATA_SOURCE]:-}" == "source" ]] && need_gb=4
	local avail_kb
	avail_kb=$(df --output=avail -k / 2>/dev/null | tail -n1 | tr -d ' ')
	if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
		local need_kb=$((need_gb * 1024 * 1024))
		if ((avail_kb < need_kb)); then
			reasons+=("at least ${need_gb} GB of free space is needed, there is less")
		fi
	fi

	# The repositories the selected steps are going to use must answer now,
	# not in the middle of the install.
	local probe
	local -a probes=()
	if [[ "${CONF[SURICATA_SOURCE]:-}" == "oisf" ]]; then
		if [[ "$OS_FAMILY" == "dnf" ]]; then
			# The repo file exists only for chroots the project builds for:
			# a missing one (a new Rocky release, say) must stop here with
			# code 3, not in the middle of `dnf copr enable`.
			local chroot
			chroot=$(copr_chroot)
			if [[ -n "$chroot" ]]; then
				probes+=("OISF COPR for $chroot|${OISF_COPR_REPO_URL:-https://copr.fedorainfracloud.org/coprs/g/oisf/suricata-8.0/repo/${chroot}/group_oisf-suricata-8.0-${chroot}.repo}")
			else
				probes+=("OISF COPR|https://copr.fedorainfracloud.org/coprs/g/oisf/suricata-8.0/")
			fi
		else
			probes+=("OISF PPA|https://ppa.launchpadcontent.net/oisf/suricata-stable/ubuntu/")
		fi
	fi
	if preflight_step_wanted ntopng; then
		if [[ "$OS_FAMILY" == "dnf" ]]; then
			probes+=("ntop.org|${NTOP_REPO_RPM_URL:-https://packages.ntop.org/centos-stable/ntop.repo}")
		else
			probes+=("ntop.org|${NTOP_REPO_DEB_URL_APT:-https://packages.ntop.org/apt-stable}/")
		fi
	fi
	if preflight_step_wanted evebox; then
		if [[ "$OS_FAMILY" == "dnf" ]]; then
			probes+=("EveBox|${EVEBOX_RPM_RELEASE_URL:-https://evebox.org/files/rpm/stable/evebox-release.noarch.rpm}")
		else
			probes+=("EveBox|${EVEBOX_REPO_URL:-https://evebox.org/files/debian}/")
		fi
	fi
	for probe in "${probes[@]}"; do
		if ! curl -fsS --max-time 5 -o /dev/null -- "${probe#*|}"; then
			reasons+=("repository ${probe%%|*} is unavailable (${probe#*|})")
		fi
	done

	if [[ "${CONF[EVEBOX_DB]:-sqlite}" == "elasticsearch" ]]; then
		if ! curl -fsS --max-time 5 -o /dev/null -- "${CONF[EVEBOX_ES_URL]:-}"; then
			reasons+=("Elasticsearch from EVEBOX_ES_URL (${CONF[EVEBOX_ES_URL]:-}) is unavailable")
		fi
	fi

	# A busy port stops a run without a terminal; the menu asks for another
	# one instead (preflight_resolve_ports_interactive). The reason names the
	# holder and a free port to pass with --set.
	local pline pkey pport pwho psuggest pkind
	while IFS= read -r pline; do
		[[ -z "$pline" ]] && continue
		IFS='|' read -r pkey pport pwho psuggest pkind <<<"$pline"
		if [[ "$pkind" == "nginx" ]]; then
			reasons+=("port $pport ($pkey) is already busy, and nginx must listen on it (held by: $pwho)${psuggest:+; free: --set $pkey=$psuggest}")
		else
			reasons+=("port $pport ($pkey) is already busy (held by: $pwho)${psuggest:+; free: --set $pkey=$psuggest}")
		fi
	done < <(preflight_port_conflicts)

	if command -v getenforce >/dev/null 2>&1; then
		log "INFO" "SELinux: $(getenforce 2>/dev/null || echo unknown)"
	fi

	printf '%s\n' "${reasons[@]}"
}

step_preflight_check() {
	local reasons
	reasons=$(step_preflight_reasons)
	if [[ -n "$reasons" ]]; then
		echo "preflight: problems found:" >&2
		echo "  - ${reasons//$'\n'/$'\n  - '}" >&2
		return 1
	fi
	return 0
}

step_preflight_apply() {
	# The real gate already ran via step_preflight_check before
	# run_plan/run_apply started; nothing left to change here.
	return 0
}

step_preflight_plan() {
	echo "preflight: no changes"
}
