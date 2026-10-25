#!/usr/bin/env bash
# Metrics backend (slice 28): VictoriaMetrics single-node or Prometheus,
# native or docker, scraping GET /metrics of the panel. METRICS_BACKEND=none
# means only the endpoint exists and the user brings their own collector
# (README), so the step has nothing to install - and stops a backend this
# installer started earlier, keeping its data (removed only by --purge).
#
# Native binaries come from the projects' GitHub releases: a pinned
# version and the pinned sha256 of the tarball (A10, tech.md). The pins
# below were taken from the release checksum files; DPISTACK_METRICS_*
# overrides exist for tests and for moving to a newer release by hand.

METRICS_USER="dpistack-metrics"
METRICS_VM_VERSION="${DPISTACK_METRICS_VM_VERSION:-v1.153.0}"
METRICS_PROM_VERSION="${DPISTACK_METRICS_PROM_VERSION:-v3.15.0}"
declare -A METRICS_SHA256=(
	[vm_amd64]="1b495bde563825cf83dc7c0425a9d8fa03e7214858e0949f9177efc6bb1f8bfc"
	[vm_arm64]="3d5f965b7a75f713742a7f37195c1d845f47d9dc9d096a2cce29e693f08fd641"
	[prom_amd64]="2a542df32eac02ee17b9d844fb2aa1de00dafa5476579ba8a3ba862e9d572ea0"
	[prom_arm64]="f1f90ec08e849d494ca66c611470afc50192f0355f1a61c33f2cbde02d067823"
)

metrics_backend() { echo "${CONF[METRICS_BACKEND]:-none}"; }

# metrics_kind <backend> - vm|prom, the short name of the pins above.
metrics_kind() {
	case "$1" in
	victoriametrics) echo vm ;;
	prometheus) echo prom ;;
	esac
}

metrics_unit_name() {
	case "$1" in
	victoriametrics) echo "dpistack-vm.service" ;;
	prometheus) echo "prometheus.service" ;;
	esac
}

metrics_port() {
	local p="${CONF[METRICS_BACKEND_PORT]:-}"
	if [[ -n "$p" ]]; then
		echo "$p"
	elif [[ "$1" == "victoriametrics" ]]; then
		echo 8428
	else
		echo 9090
	fi
}

# The backend is not proxied by nginx, so it is reachable only where the
# bind says: 0.0.0.0 in lan mode, 127.0.0.1 otherwise.
metrics_listen() { echo "$(access_effective_bind_host):$(metrics_port "$1")"; }

metrics_version() {
	case "$1" in
	victoriametrics) echo "$METRICS_VM_VERSION" ;;
	prometheus) echo "$METRICS_PROM_VERSION" ;;
	esac
}

metrics_arch() {
	case "${DPISTACK_METRICS_ARCH:-$(uname -m)}" in
	x86_64 | amd64) echo amd64 ;;
	aarch64 | arm64) echo arm64 ;;
	*) return 1 ;;
	esac
}

metrics_runtime() { echo "${CONF[METRICS_BACKEND_RUNTIME]:-native}"; }

# The panel's own listening port: behind nginx it is PORT+10000 over plain
# HTTP, which is what the collector can reach without TLS.
metrics_scrape_target() {
	local host
	host=$(access_effective_bind_host)
	[[ "$host" == "0.0.0.0" ]] && host="127.0.0.1"
	echo "${host}:$(access_backend_port "${CONF[PANEL_PORT]:-9800}")"
}

metrics_render_scrape() {
	render_template "$SCRIPT_DIR/templates/scrape.yaml.tpl" \
		"TOKEN_FILE=$(path_metrics_token)" \
		"TARGET=$(metrics_scrape_target)"
	# node_exporter is scraped by the same backend when it is installed.
	if nodeexp_wanted; then
		printf '  - job_name: node\n    static_configs:\n      - targets: ['"'"'%s'"'"']\n' "$(nodeexp_target)"
	fi
}

metrics_render_unit() {
	local backend="$1" tpl bin
	case "$backend" in
	victoriametrics)
		tpl=dpistack-vm.service.tpl
		bin=$(path_vm_bin)
		;;
	prometheus)
		tpl=prometheus.service.tpl
		bin=$(path_prometheus_bin)
		;;
	esac
	render_template "$SCRIPT_DIR/templates/$tpl" \
		"USER=$METRICS_USER" \
		"BIN=$bin" \
		"DATA_DIR=$(metrics_data_dir "$backend")" \
		"RETENTION=${CONF[METRICS_RETENTION]:-30d}" \
		"LISTEN=$(metrics_listen "$backend")" \
		"SCRAPE=$(path_scrape_yaml)"
}

metrics_data_dir() { echo "$(path_metrics_data_dir)/$1"; }

metrics_unit_path() {
	case "$1" in
	victoriametrics) path_vm_unit ;;
	prometheus) path_prometheus_unit ;;
	esac
}

metrics_bin_path() {
	case "$1" in
	victoriametrics) path_vm_bin ;;
	prometheus) path_prometheus_bin ;;
	esac
}

# What this installer started last: "<runtime>:<backend>[:<version>]".
metrics_installed() { state_read_value "metrics.backend" 2>/dev/null || true; }

metrics_marker() {
	local backend="$1"
	if [[ "$(metrics_runtime)" == "docker" ]]; then
		echo "docker:$backend"
	else
		echo "native:$backend:$(metrics_version "$backend")"
	fi
}

metrics_file_current() {
	local path="$1" content="$2"
	[[ -f "$path" ]] || return 1
	[[ "$(printf '%s\n' "$content" | state_hash_content)" == "$(state_hash_content <"$path")" ]]
}

step_metrics_check() {
	local backend installed
	backend=$(metrics_backend)
	installed=$(metrics_installed)
	if [[ "$backend" == "none" ]]; then
		# A backend started earlier must be stopped.
		[[ -z "$installed" ]]
		return
	fi
	[[ "$installed" == "$(metrics_marker "$backend")" ]] || return 1
	metrics_file_current "$(path_scrape_yaml)" "$(metrics_render_scrape)" || return 1
	if [[ "$(metrics_runtime)" == "docker" ]]; then
		docker_service_check "$backend"
		return
	fi
	[[ -x "$(metrics_bin_path "$backend")" ]] || return 1
	metrics_file_current "$(metrics_unit_path "$backend")" "$(metrics_render_unit "$backend")" || return 1
	systemctl is-active --quiet "$(metrics_unit_name "$backend")"
}

# metrics_stop_installed - stop what the state says was started, whatever
# the backend is now. Data and the token stay.
metrics_stop_installed() {
	local installed runtime backend
	installed=$(metrics_installed)
	[[ -n "$installed" ]] || return 0
	runtime="${installed%%:*}"
	backend="${installed#*:}"
	backend="${backend%%:*}"
	if [[ "$runtime" == "docker" ]]; then
		if command -v docker >/dev/null 2>&1 && [[ -f "$(path_compose_yaml)" ]]; then
			docker_compose_argv
			run "${DOCKER_COMPOSE_ARGV[@]}" rm -fsv "$backend" || return 1
		fi
	else
		run systemctl disable --now "$(metrics_unit_name "$backend")" 2>/dev/null || true
	fi
	return 0
}

# The users and the token file exist before the backend starts: Prometheus
# refuses a config whose credentials_file is missing. The panel step
# writes the same file later with the same owner.
metrics_ensure_users() {
	if ! getent passwd dpistack >/dev/null 2>&1; then
		run useradd --system --no-create-home --shell /usr/sbin/nologin dpistack || return 1
	fi
	if ! getent passwd "$METRICS_USER" >/dev/null 2>&1; then
		run useradd --system --no-create-home --shell /usr/sbin/nologin -G dpistack "$METRICS_USER" || return 1
	fi
	local tfile
	tfile=$(path_metrics_token)
	if panel_token_wanted && [[ ! -s "$tfile" && "${DRY_RUN:-0}" != "1" ]]; then
		printf '%s\n' "${SECRETS[METRICS_TOKEN]}" | atomic_write "$tfile" 0640 || return 1
		run chown "root:dpistack" "$tfile" || return 1
	fi
	return 0
}

# metrics_fetch_binary <backend> - download, verify the sha256, install.
metrics_fetch_binary() {
	local backend="$1" kind arch ver url tmp want got
	kind=$(metrics_kind "$backend")
	arch=$(metrics_arch) || {
		echo "metrics: architecture $(uname -m) is not supported (amd64 or arm64 is needed)" >&2
		return 1
	}
	ver=$(metrics_version "$backend")
	if [[ "$backend" == "victoriametrics" ]]; then
		url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${ver}/victoria-metrics-linux-${arch}-${ver}.tar.gz"
	else
		url="https://github.com/prometheus/prometheus/releases/download/${ver}/prometheus-${ver#v}.linux-${arch}.tar.gz"
	fi
	local override="DPISTACK_METRICS_SHA256_${kind^^}_${arch^^}"
	want="${!override:-${METRICS_SHA256[${kind}_${arch}]}}"
	tmp=$(mktemp -d)
	if ! run curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/archive.tar.gz" "$url"; then
		echo "metrics: could not download $url" >&2
		rm -rf "$tmp"
		return 1
	fi
	got=$(sha256sum "$tmp/archive.tar.gz" | awk '{print $1}')
	if [[ "$got" != "$want" ]]; then
		echo "metrics: the checksum of $url did not match (expected $want, got $got), the binary is not installed" >&2
		rm -rf "$tmp"
		return 1
	fi
	run tar -xzf "$tmp/archive.tar.gz" -C "$tmp" || {
		rm -rf "$tmp"
		return 1
	}
	local src
	if [[ "$backend" == "victoriametrics" ]]; then
		src="$tmp/victoria-metrics-prod"
	else
		src="$tmp/prometheus-${ver#v}.linux-${arch}/prometheus"
	fi
	run install -D -m 0755 "$src" "$(metrics_bin_path "$backend")" || {
		rm -rf "$tmp"
		return 1
	}
	rm -rf "$tmp"
	return 0
}

step_metrics_apply() {
	local backend installed marker
	backend=$(metrics_backend)
	installed=$(metrics_installed)
	# A new pinned version (or another runtime) changes the marker: the
	# binary then has to be fetched again, or the state would claim a
	# version the old binary is not.
	local refetch=0
	[[ -n "$installed" && "$installed" != "$(metrics_marker "$backend")" ]] && refetch=1

	# A backend that is no longer wanted (none, or the other one, or the
	# other runtime) is stopped first; its data stays.
	if [[ -n "$installed" && "$installed" != "$(metrics_marker "$backend")" ]]; then
		metrics_stop_installed || return 1
		state_write_value "metrics.backend" "" || return 1
	fi
	[[ "$backend" == "none" ]] && return 0

	metrics_ensure_users || return 1
	local d
	d=$(metrics_data_dir "$backend")
	run install -d -m 0750 "$d" || return 1
	run chown "$METRICS_USER:" "$d" || return 1
	# scrape.yaml holds no secret; the backend user must reach it, and the
	# state directory only has to be traversable, not listable.
	run chmod o+x "$(path_state_dir)" || return 1
	write_rendered_file "$(path_scrape_yaml)" "$(metrics_render_scrape)" 0644 || return 1

	if [[ "$(metrics_runtime)" == "docker" ]]; then
		docker_service_apply "$backend" || return 1
	else
		if [[ ! -x "$(metrics_bin_path "$backend")" || "$refetch" == "1" ]]; then
			metrics_fetch_binary "$backend" || return 1
		fi
		write_rendered_file "$(metrics_unit_path "$backend")" "$(metrics_render_unit "$backend")" || return 1
		run systemctl daemon-reload || return 1
		run systemctl enable --now "$(metrics_unit_name "$backend")" || return 1
		# A changed unit or scrape file is only read after a restart.
		run systemctl restart "$(metrics_unit_name "$backend")" || return 1
	fi
	marker=$(metrics_marker "$backend")
	state_write_value "metrics.backend" "$marker"
}

step_metrics_plan() {
	local backend installed
	backend=$(metrics_backend)
	installed=$(metrics_installed)
	if [[ -n "$installed" && "$installed" != "$(metrics_marker "$backend")" ]]; then
		echo "metrics: stop ${installed} (the data stays)"
	fi
	if [[ "$backend" == "none" ]]; then
		[[ -z "$installed" ]] && echo "metrics: no changes (METRICS_BACKEND=none, only the /metrics endpoint)"
		return 0
	fi
	if [[ "$(metrics_runtime)" == "docker" ]]; then
		docker_service_plan "$backend"
	else
		echo "metrics: $backend $(metrics_version "$backend") from a GitHub release with a sha256 check, unit $(metrics_unit_name "$backend"), listens on $(metrics_listen "$backend"), retention ${CONF[METRICS_RETENTION]:-30d}"
	fi
	echo "metrics: render $(path_scrape_yaml), target $(metrics_scrape_target), token from file $(path_metrics_token)"
}
