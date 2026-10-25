#!/usr/bin/env bash
# Grafana: dashboards over the metrics backend. Optional (GRAFANA_ENABLE),
# native or docker. The native build is the vendor tarball from
# dl.grafana.com; its sha256 comes from the vendor's .sha256 file next to the
# tarball, fetched over TLS at install time (DPISTACK_GRAFANA_SHA256 pins it
# by hand). With a metrics backend selected the backend is provisioned as the
# default data source. Grafana's own first login is admin/admin and asks for
# a new password.

GRAFANA_VERSION="${DPISTACK_GRAFANA_VERSION:-12.2.0}"

grafana_wanted() { [[ "${CONF[GRAFANA_ENABLE]:-no}" == "yes" ]]; }
grafana_runtime() { echo "${CONF[GRAFANA_RUNTIME]:-native}"; }
grafana_port() { echo "${CONF[GRAFANA_PORT]:-3030}"; }

grafana_marker() {
	if [[ "$(grafana_runtime)" == "docker" ]]; then
		echo "docker:grafana"
	else
		echo "native:grafana:${GRAFANA_VERSION}"
	fi
}
grafana_installed() { state_read_value "grafana.installed" 2>/dev/null || true; }

# grafana_datasource_url - host:port of the metrics backend, empty without one.
grafana_datasource_url() {
	local backend="${CONF[METRICS_BACKEND]:-none}"
	[[ "$backend" == "none" ]] && return 0
	echo "$(access_connect_host):$(metrics_port "$backend")"
}

grafana_render_ini() {
	render_template "$SCRIPT_DIR/templates/grafana.ini.tpl" \
		"DATA=$(path_grafana_data_dir)" "PROV=$(path_grafana_prov_dir)" \
		"ADDR=$(access_effective_bind_host)" "PORT=$(grafana_port)"
}

grafana_render_unit() {
	render_template "$SCRIPT_DIR/templates/grafana.service.tpl" \
		"USER=$MONITOR_USER" "HOME=$(path_grafana_home)" "INI=$(path_grafana_ini)"
}

grafana_render_datasource() {
	local url
	url=$(grafana_datasource_url)
	[[ -n "$url" ]] || return 0
	render_template "$SCRIPT_DIR/templates/grafana-datasource.yaml.tpl" "URL=$url"
}

grafana_datasource_path() { echo "$(path_grafana_prov_dir)/datasources/dpistack.yaml"; }

# grafana_files_current - the ini and the data source on disk are what this
# config renders (no data source file when there is no backend).
grafana_files_current() {
	metrics_file_current "$(path_grafana_ini)" "$(grafana_render_ini)" || return 1
	local ds
	ds=$(grafana_render_datasource)
	if [[ -n "$ds" ]]; then
		metrics_file_current "$(grafana_datasource_path)" "$ds" || return 1
	else
		[[ ! -e "$(grafana_datasource_path)" ]] || return 1
	fi
}

grafana_arch() { nodeexp_arch; }

grafana_fetch() {
	local arch url tmp want got
	arch=$(grafana_arch) || {
		echo "grafana: architecture $(uname -m) is not supported (amd64 or arm64 is needed)" >&2
		return 1
	}
	url="https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-${arch}.tar.gz"
	tmp=$(mktemp -d)
	if ! run curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/archive.tar.gz" "$url"; then
		echo "grafana: could not download $url" >&2
		rm -rf "$tmp"
		return 1
	fi
	want="${DPISTACK_GRAFANA_SHA256:-}"
	if [[ -z "$want" ]]; then
		if ! want=$(curl --proto '=https' --tlsv1.2 -fsSL "${url}.sha256" 2>/dev/null | awk '{print $1; exit}') || [[ -z "$want" ]]; then
			echo "grafana: could not read the vendor checksum ${url}.sha256, the binary is not installed" >&2
			rm -rf "$tmp"
			return 1
		fi
	fi
	got=$(sha256sum "$tmp/archive.tar.gz" | awk '{print $1}')
	if [[ "$got" != "$want" ]]; then
		echo "grafana: the checksum of $url did not match (expected $want, got $got), the binary is not installed" >&2
		rm -rf "$tmp"
		return 1
	fi
	local home
	home=$(path_grafana_home)
	run rm -rf "$home" || return 1
	run install -d -m 0755 "$home" || return 1
	run tar -xzf "$tmp/archive.tar.gz" -C "$home" --strip-components=1 || {
		rm -rf "$tmp"
		return 1
	}
	rm -rf "$tmp"
}

grafana_stop_installed() {
	local installed runtime
	installed=$(grafana_installed)
	[[ -n "$installed" ]] || return 0
	runtime="${installed%%:*}"
	if [[ "$runtime" == "docker" ]]; then
		if command -v docker >/dev/null 2>&1 && [[ -f "$(path_compose_yaml)" ]]; then
			docker_compose_argv
			run "${DOCKER_COMPOSE_ARGV[@]}" rm -fsv grafana || return 1
		fi
	else
		run systemctl disable --now "dpistack-grafana.service" 2>/dev/null || true
	fi
	return 0
}

# grafana_write_files - the ini, the data source and the directories.
grafana_write_files() {
	local d
	for d in "$(path_grafana_data_dir)" "$(path_grafana_prov_dir)/datasources"; do
		run install -d -m 0750 "$d" || return 1
	done
	run chown -R "$MONITOR_USER:" "$(path_grafana_data_dir)" || return 1
	run chmod o+x "$(dirname "$(path_grafana_ini)")" || return 1
	write_rendered_file "$(path_grafana_ini)" "$(grafana_render_ini)" 0644 || return 1
	local ds
	ds=$(grafana_render_datasource)
	if [[ -n "$ds" ]]; then
		write_rendered_file "$(grafana_datasource_path)" "$ds" 0644 || return 1
		run chmod -R o+rX "$(path_grafana_prov_dir)" || return 1
	else
		run rm -f "$(grafana_datasource_path)" || return 1
	fi
}

step_grafana_check() {
	local installed
	installed=$(grafana_installed)
	if ! grafana_wanted; then
		[[ -z "$installed" ]]
		return
	fi
	[[ "$installed" == "$(grafana_marker)" ]] || return 1
	grafana_files_current || return 1
	if [[ "$(grafana_runtime)" == "docker" ]]; then
		docker_service_check grafana
		return
	fi
	[[ -x "$(path_grafana_home)/bin/grafana" ]] || return 1
	metrics_file_current "$(path_grafana_unit)" "$(grafana_render_unit)" || return 1
	systemctl is-active --quiet "dpistack-grafana.service"
}

step_grafana_apply() {
	local installed refetch=0
	installed=$(grafana_installed)
	if [[ -n "$installed" ]] && { ! grafana_wanted || [[ "$installed" != "$(grafana_marker)" ]]; }; then
		refetch=1
		grafana_stop_installed || return 1
		state_write_value "grafana.installed" "" || return 1
	fi
	grafana_wanted || return 0

	monitor_ensure_user || return 1
	grafana_write_files || return 1
	if [[ "$(grafana_runtime)" == "docker" ]]; then
		docker_service_apply grafana || return 1
	else
		if [[ ! -x "$(path_grafana_home)/bin/grafana" || "$refetch" == "1" ]]; then
			grafana_fetch || return 1
		fi
		write_rendered_file "$(path_grafana_unit)" "$(grafana_render_unit)" || return 1
		run systemctl daemon-reload || return 1
		run systemctl enable --now "dpistack-grafana.service" || return 1
		run systemctl restart "dpistack-grafana.service" || return 1
	fi
	echo "grafana: listens on $(access_effective_bind_host):$(grafana_port); the first login is admin/admin, Grafana asks for a new password at once." >&2
	state_write_value "grafana.installed" "$(grafana_marker)"
}

step_grafana_plan() {
	local installed
	installed=$(grafana_installed)
	if [[ -n "$installed" ]] && { ! grafana_wanted || [[ "$installed" != "$(grafana_marker)" ]]; }; then
		echo "grafana: stop ${installed}"
	fi
	if ! grafana_wanted; then
		[[ -z "$installed" ]] && echo "grafana: no changes (GRAFANA_ENABLE=no)"
		return 0
	fi
	if [[ "$(grafana_runtime)" == "docker" ]]; then
		docker_service_plan grafana
	else
		echo "grafana: Grafana ${GRAFANA_VERSION} from dl.grafana.com with a sha256 check, unit dpistack-grafana.service, listens on $(access_effective_bind_host):$(grafana_port)"
	fi
	local url
	url=$(grafana_datasource_url)
	echo "grafana: data source ${url:-none (no metrics backend)}"
}
