#!/usr/bin/env bash
# node_exporter: host metrics (CPU, memory, disk, network) for the metrics
# backend. Optional (NODE_EXPORTER_ENABLE), native or docker. The native
# binary comes from the project's GitHub release with a pinned sha256
# (DPISTACK_NODEEXP_* override the pins for tests and for moving to a newer
# release by hand).

MONITOR_USER="dpistack-monitor"
NODEEXP_VERSION="${DPISTACK_NODEEXP_VERSION:-v1.12.1}"
declare -A NODEEXP_SHA256=(
	[amd64]="b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63"
	[arm64]="ad35b605f9954b9f1ffddf5ba054bdc5a98d790b9eae5291e1eeb83f1ecbd0e7"
)

nodeexp_wanted() { [[ "${CONF[NODE_EXPORTER_ENABLE]:-no}" == "yes" ]]; }
nodeexp_runtime() { echo "${CONF[NODE_EXPORTER_RUNTIME]:-native}"; }
nodeexp_port() { echo "${CONF[NODE_EXPORTER_PORT]:-9100}"; }
nodeexp_listen() { echo "$(access_effective_bind_host):$(nodeexp_port)"; }

# nodeexp_target - where the metrics backend scrapes it (same host).
nodeexp_target() { echo "$(access_connect_host):$(nodeexp_port)"; }

nodeexp_marker() {
	if [[ "$(nodeexp_runtime)" == "docker" ]]; then
		echo "docker:node_exporter"
	else
		echo "native:node_exporter:${NODEEXP_VERSION}"
	fi
}
nodeexp_installed() { state_read_value "nodeexp.installed" 2>/dev/null || true; }

nodeexp_render_unit() {
	render_template "$SCRIPT_DIR/templates/node-exporter.service.tpl" \
		"USER=$MONITOR_USER" "BIN=$(path_nodeexp_bin)" "LISTEN=$(nodeexp_listen)"
}

nodeexp_arch() {
	case "${DPISTACK_METRICS_ARCH:-$(uname -m)}" in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) return 1 ;;
	esac
}

# monitor_ensure_user - the system user of node_exporter and Grafana.
monitor_ensure_user() {
	getent passwd "$MONITOR_USER" >/dev/null 2>&1 && return 0
	run useradd --system --no-create-home --shell /usr/sbin/nologin "$MONITOR_USER"
}

nodeexp_fetch_binary() {
	local arch ver url tmp want got
	arch=$(nodeexp_arch) || {
		echo "node_exporter: architecture $(uname -m) is not supported (amd64 or arm64 is needed)" >&2
		return 1
	}
	ver="$NODEEXP_VERSION"
	url="https://github.com/prometheus/node_exporter/releases/download/${ver}/node_exporter-${ver#v}.linux-${arch}.tar.gz"
	local override="DPISTACK_NODEEXP_SHA256_${arch^^}"
	want="${!override:-${NODEEXP_SHA256[$arch]}}"
	tmp=$(mktemp -d)
	if ! run curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/archive.tar.gz" "$url"; then
		echo "node_exporter: could not download $url" >&2
		rm -rf "$tmp"
		return 1
	fi
	got=$(sha256sum "$tmp/archive.tar.gz" | awk '{print $1}')
	if [[ "$got" != "$want" ]]; then
		echo "node_exporter: the checksum of $url did not match (expected $want, got $got), the binary is not installed" >&2
		rm -rf "$tmp"
		return 1
	fi
	run tar -xzf "$tmp/archive.tar.gz" -C "$tmp" || {
		rm -rf "$tmp"
		return 1
	}
	run install -D -m 0755 "$tmp/node_exporter-${ver#v}.linux-${arch}/node_exporter" "$(path_nodeexp_bin)" || {
		rm -rf "$tmp"
		return 1
	}
	rm -rf "$tmp"
}

nodeexp_stop_installed() {
	local installed runtime
	installed=$(nodeexp_installed)
	[[ -n "$installed" ]] || return 0
	runtime="${installed%%:*}"
	if [[ "$runtime" == "docker" ]]; then
		if command -v docker >/dev/null 2>&1 && [[ -f "$(path_compose_yaml)" ]]; then
			docker_compose_argv
			run "${DOCKER_COMPOSE_ARGV[@]}" rm -fsv node_exporter || return 1
		fi
	else
		run systemctl disable --now "dpistack-node-exporter.service" 2>/dev/null || true
	fi
	return 0
}

step_nodeexp_check() {
	local installed
	installed=$(nodeexp_installed)
	if ! nodeexp_wanted; then
		[[ -z "$installed" ]]
		return
	fi
	[[ "$installed" == "$(nodeexp_marker)" ]] || return 1
	if [[ "$(nodeexp_runtime)" == "docker" ]]; then
		docker_service_check node_exporter
		return
	fi
	[[ -x "$(path_nodeexp_bin)" ]] || return 1
	metrics_file_current "$(path_nodeexp_unit)" "$(nodeexp_render_unit)" || return 1
	systemctl is-active --quiet "dpistack-node-exporter.service"
}

step_nodeexp_apply() {
	local installed refetch=0
	installed=$(nodeexp_installed)
	if [[ -n "$installed" ]] && { ! nodeexp_wanted || [[ "$installed" != "$(nodeexp_marker)" ]]; }; then
		refetch=1
		nodeexp_stop_installed || return 1
		state_write_value "nodeexp.installed" "" || return 1
	fi
	nodeexp_wanted || return 0

	if [[ "$(nodeexp_runtime)" == "docker" ]]; then
		docker_service_apply node_exporter || return 1
	else
		monitor_ensure_user || return 1
		if [[ ! -x "$(path_nodeexp_bin)" || "$refetch" == "1" ]]; then
			nodeexp_fetch_binary || return 1
		fi
		write_rendered_file "$(path_nodeexp_unit)" "$(nodeexp_render_unit)" || return 1
		run systemctl daemon-reload || return 1
		run systemctl enable --now "dpistack-node-exporter.service" || return 1
		run systemctl restart "dpistack-node-exporter.service" || return 1
	fi
	state_write_value "nodeexp.installed" "$(nodeexp_marker)"
}

step_nodeexp_plan() {
	local installed
	installed=$(nodeexp_installed)
	if [[ -n "$installed" ]] && { ! nodeexp_wanted || [[ "$installed" != "$(nodeexp_marker)" ]]; }; then
		echo "nodeexp: stop ${installed}"
	fi
	if ! nodeexp_wanted; then
		[[ -z "$installed" ]] && echo "nodeexp: no changes (NODE_EXPORTER_ENABLE=no)"
		return 0
	fi
	if [[ "$(nodeexp_runtime)" == "docker" ]]; then
		docker_service_plan node_exporter
	else
		echo "nodeexp: node_exporter ${NODEEXP_VERSION} from a GitHub release with a sha256 check, unit dpistack-node-exporter.service, listens on $(nodeexp_listen)"
	fi
}
