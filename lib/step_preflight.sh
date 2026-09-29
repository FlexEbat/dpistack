#!/usr/bin/env bash
# Real preflight (tech.md 5.5). Runs once, before any package gets
# installed; collects every failure reason instead of stopping at the
# first one (install.sh's cmd_install dies with all of them, code 3).

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

	local key
	for key in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME METRICS_BACKEND_RUNTIME; do
		if [[ "${CONF[$key]:-}" == "docker" ]] && ! command -v docker >/dev/null 2>&1; then
			reasons+=("$key=docker, но docker не найден")
		fi
	done

	if [[ "${OS_FAMILY:-}" == "dnf" ]]; then
		reasons+=("dnf-дистрибутив: пока не поддерживается")
	fi

	local iface _preflight_ifaces
	IFS=',' read -ra _preflight_ifaces <<<"${CONF[IFACES]:-}"
	for iface in "${_preflight_ifaces[@]}"; do
		[[ -z "$iface" ]] && continue
		if ! ip link show "$iface" >/dev/null 2>&1; then
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

	if [[ "${CONF[SURICATA_SOURCE]:-}" == "oisf" ]]; then
		if ! curl -fsS --max-time 5 -o /dev/null "https://ppa.launchpadcontent.net/oisf/suricata-stable/ubuntu/"; then
			reasons+=("репозиторий OISF PPA недоступен")
		fi
	fi

	if [[ "${CONF[EVEBOX_DB]:-sqlite}" == "elasticsearch" ]]; then
		if ! curl -fsS --max-time 5 -o /dev/null "${CONF[EVEBOX_ES_URL]:-}"; then
			reasons+=("Elasticsearch из EVEBOX_ES_URL (${CONF[EVEBOX_ES_URL]:-}) недоступен")
		fi
	fi

	# A port held by a service dpistack already installed is not a
	# conflict on a repeat run, so ports whose step is already applied
	# are skipped.
	local port_key port owner_step
	for port_key in NTOPNG_PORT EVEBOX_PORT PANEL_PORT METRICS_BACKEND_PORT; do
		port="${CONF[$port_key]:-}"
		[[ -z "$port" ]] && continue
		case "$port_key" in
		NTOPNG_PORT) owner_step=ntopng ;;
		EVEBOX_PORT) owner_step=evebox ;;
		PANEL_PORT) owner_step=panel ;;
		METRICS_BACKEND_PORT) owner_step=metrics ;;
		esac
		if "step_${owner_step}_check"; then
			continue
		fi
		if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
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
