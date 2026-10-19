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

# preflight_panel_reasons - the panel binary has to be obtainable before
# the install starts: a ready file for prebuilt, Go (at least the version
# panel/go.mod asks for) for build. A binary that is already installed and
# current needs neither, so a repeat run on a host without Go still passes.
preflight_panel_reasons() {
	panel_bin_current && return 0
	if [[ "$(panel_source_mode)" == "prebuilt" ]]; then
		if [[ ! -f "$(panel_prebuilt_path)" ]]; then
			reasons+=("PANEL_SOURCE=prebuilt, но рядом с install.sh нет готового бинарника dpistack-panel (в архиве релиза он называется $(basename "$(panel_prebuilt_path)"))")
		fi
		return 0
	fi
	if [[ ! -d "$SCRIPT_DIR/panel" ]]; then
		reasons+=("панель нечем взять: рядом с install.sh нет ни готового бинарника ($(basename "$(panel_prebuilt_path)")), ни каталога panel/ с исходниками")
		return 0
	fi
	local need have
	need=$(awk '/^go /{print $2; exit}' "$SCRIPT_DIR/panel/go.mod" 2>/dev/null)
	if ! command -v go >/dev/null 2>&1; then
		reasons+=("панель нечем взять: нет Go (нужен Go ${need:-новее}) и рядом с install.sh нет готового бинарника ($(basename "$(panel_prebuilt_path)"))")
		return 0
	fi
	have=$(go version 2>/dev/null | sed -n 's/^go version go\([0-9][0-9.]*\).*/\1/p')
	if [[ -n "$need" && -n "$have" && "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" != "$need" ]]; then
		reasons+=("панель нечем взять: Go $have старше требуемого $need и рядом с install.sh нет готового бинарника ($(basename "$(panel_prebuilt_path)"))")
	fi
}

step_preflight_reasons() {
	local reasons=()

	if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
		reasons+=("нужны права root")
	fi

	if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
		reasons+=("нужен Bash 4.4+, сейчас ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}")
	fi

	if ! command -v systemctl >/dev/null 2>&1; then
		reasons+=("systemd (systemctl) не найден, нужен для native runtime")
	fi

	if preflight_step_wanted panel; then
		preflight_panel_reasons
	fi

	local key
	for key in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME METRICS_BACKEND_RUNTIME; do
		if [[ "${CONF[$key]:-}" == "docker" ]] && ! command -v docker >/dev/null 2>&1; then
			reasons+=("$key=docker, но docker не найден")
		fi
	done

	if [[ "${CONF[SURICATA_MODE]:-ids}" == "ips" && "${CONF[IPS_METHOD]:-nfq}" == "nfq" ]] && ! command -v iptables >/dev/null 2>&1; then
		reasons+=("SURICATA_MODE=ips с IPS_METHOD=nfq: не найден iptables (нужен для цепочки DPISTACK)")
	fi
	if [[ "${CONF[SURICATA_RUNTIME]:-native}" == "docker" && "${CONF[NDPI_ENABLE]:-no}" == "yes" ]]; then
		reasons+=("SURICATA_RUNTIME=docker: плагин nDPI в образ не ставится, задайте NDPI_ENABLE=no")
	fi
	if command -v docker >/dev/null 2>&1; then
		local dkey
		for dkey in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME; do
			if [[ "${CONF[$dkey]:-}" == "docker" ]] && ! docker compose version >/dev/null 2>&1; then
				reasons+=("$dkey=docker, но у docker нет плагина compose (docker compose version не отвечает)")
				break
			fi
		done
	fi

	case "$(os_support_level)" in
	unsupported)
		if [[ "${DPISTACK_ALLOW_UNSUPPORTED:-0}" != "1" ]]; then
			reasons+=("$OS_ID ${OS_VERSION_ID:-} не поддерживается (поддерживаются Ubuntu LTS от 22.04, Debian от 12, Rocky Linux и AlmaLinux от 8); продолжить на свой риск: DPISTACK_ALLOW_UNSUPPORTED=1")
		fi
		;;
	unverified)
		log "WARN" "$OS_ID ${OS_VERSION_ID:-} не входит в список проверенных платформ (tech.md 11), установка продолжится"
		;;
	esac

	local iface _preflight_ifaces
	IFS=',' read -ra _preflight_ifaces <<<"${CONF[IFACES]:-}"
	for iface in "${_preflight_ifaces[@]}"; do
		[[ -z "$iface" ]] && continue
		if ! net_iface_exists "$iface"; then
			reasons+=("интерфейс $iface из IFACES не существует")
		fi
	done

	local need_gb=1
	[[ "${CONF[SURICATA_SOURCE]:-}" == "source" ]] && need_gb=4
	local avail_kb
	avail_kb=$(df --output=avail -k / 2>/dev/null | tail -n1 | tr -d ' ')
	if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
		local need_kb=$((need_gb * 1024 * 1024))
		if ((avail_kb < need_kb)); then
			reasons+=("нужно не меньше ${need_gb}ГБ свободного места, есть меньше")
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
				probes+=("OISF COPR для $chroot|${OISF_COPR_REPO_URL:-https://copr.fedorainfracloud.org/coprs/g/oisf/suricata-8.0/repo/${chroot}/group_oisf-suricata-8.0-${chroot}.repo}")
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
			reasons+=("репозиторий ${probe%%|*} недоступен (${probe#*|})")
		fi
	done

	if [[ "${CONF[EVEBOX_DB]:-sqlite}" == "elasticsearch" ]]; then
		if ! curl -fsS --max-time 5 -o /dev/null -- "${CONF[EVEBOX_ES_URL]:-}"; then
			reasons+=("Elasticsearch из EVEBOX_ES_URL (${CONF[EVEBOX_ES_URL]:-}) недоступен")
		fi
	fi

	# A port held by a service dpistack already installed is not a
	# conflict on a repeat run, so ports whose step is already applied
	# are skipped.
	# With ACCESS_MODE=nginx both ports matter: nginx takes the public one
	# (the access step owns it), the service takes public+10000.
	local port_key port owner_step public
	for port_key in NTOPNG_PORT EVEBOX_PORT PANEL_PORT METRICS_BACKEND_PORT; do
		public="${CONF[$port_key]:-}"
		[[ -z "$public" ]] && continue
		case "$port_key" in
		NTOPNG_PORT) owner_step=ntopng ;;
		EVEBOX_PORT) owner_step=evebox ;;
		PANEL_PORT) owner_step=panel ;;
		METRICS_BACKEND_PORT) owner_step=metrics ;;
		esac
		if [[ "$port_key" != "METRICS_BACKEND_PORT" && "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
			if ! step_access_check && preflight_port_busy "$public"; then
				reasons+=("порт $public ($port_key) уже занят, а на нём должен слушать nginx")
			fi
			port=$(access_backend_port "$public")
		else
			port="$public"
		fi
		if "step_${owner_step}_check"; then
			continue
		fi
		if preflight_port_busy "$port"; then
			reasons+=("порт $port ($port_key) уже занят")
		fi
	done

	if command -v getenforce >/dev/null 2>&1; then
		log "INFO" "SELinux: $(getenforce 2>/dev/null || echo неизвестно)"
	fi

	printf '%s\n' "${reasons[@]}"
}

step_preflight_check() {
	local reasons
	reasons=$(step_preflight_reasons)
	if [[ -n "$reasons" ]]; then
		echo "preflight: обнаружены проблемы:" >&2
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
	echo "preflight: без изменений"
}
