#!/usr/bin/env bash
# Docker runtime (slice 27): suricata, evebox, ntopng and the redis behind
# ntopng as services of one compose project. Only Docker with the compose
# plugin; podman, swarm and kubernetes are out of scope.
#
# Every service uses network_mode: host, so bind addresses, ports and the
# firewall rules of the access step mean exactly what they mean for the
# native runtime, and dpistack neither creates networks nor touches
# iptables or the DOCKER-USER chain: Docker's own rules stay as they are.
# eve.json stays at the same host path (/var/log/suricata), bind-mounted
# into every container that needs it.
#
# Images and mount points are assumptions A6 (tech.md): not confirmed
# against the real images yet.

DOCKER_PROJECT="dpistack"
DOCKER_IMAGE_SURICATA="${DOCKER_IMAGE_SURICATA:-jasonish/suricata}"
DOCKER_IMAGE_EVEBOX="${DOCKER_IMAGE_EVEBOX:-jasonish/evebox}"
DOCKER_IMAGE_NTOPNG="${DOCKER_IMAGE_NTOPNG:-ntop/ntopng}"
DOCKER_IMAGE_REDIS="${DOCKER_IMAGE_REDIS:-redis}"
DOCKER_IMAGE_VICTORIAMETRICS="${DOCKER_IMAGE_VICTORIAMETRICS:-victoriametrics/victoria-metrics}"
DOCKER_IMAGE_PROMETHEUS="${DOCKER_IMAGE_PROMETHEUS:-prom/prometheus}"
# Services in start order (ntopng needs redis).
DOCKER_SERVICES_ORDER=(suricata evebox redis ntopng victoriametrics prometheus)

# docker_service_runtime <service> - native or docker, from CONF.
# redis follows ntopng: it is ntopng's own store (step_redis.sh).
docker_service_runtime() {
	case "$1" in
	suricata) echo "${CONF[SURICATA_RUNTIME]:-native}" ;;
	evebox) echo "${CONF[EVEBOX_RUNTIME]:-native}" ;;
	redis | ntopng) echo "${CONF[NTOPNG_RUNTIME]:-native}" ;;
	# A backend is a docker service only when it is the selected one.
	victoriametrics | prometheus)
		if [[ "${CONF[METRICS_BACKEND]:-none}" == "$1" ]]; then
			echo "${CONF[METRICS_BACKEND_RUNTIME]:-native}"
		else
			echo native
		fi
		;;
	*) echo native ;;
	esac
}

docker_wanted() { [[ "$(docker_service_runtime "$1")" == "docker" ]]; }

docker_services() {
	local s
	for s in "${DOCKER_SERVICES_ORDER[@]}"; do
		docker_wanted "$s" && echo "$s"
	done
	return 0
}

# docker_image <service> - image:tag. A pinned *_VERSION is the tag.
docker_image() {
	case "$1" in
	suricata) echo "${DOCKER_IMAGE_SURICATA}:${CONF[SURICATA_VERSION]:-${DOCKER_TAG_SURICATA:-latest}}" ;;
	evebox) echo "${DOCKER_IMAGE_EVEBOX}:${CONF[EVEBOX_VERSION]:-${DOCKER_TAG_EVEBOX:-latest}}" ;;
	ntopng) echo "${DOCKER_IMAGE_NTOPNG}:${CONF[NTOPNG_VERSION]:-${DOCKER_TAG_NTOPNG:-stable}}" ;;
	redis) echo "${DOCKER_IMAGE_REDIS}:${DOCKER_TAG_REDIS:-7-alpine}" ;;
	victoriametrics) echo "${DOCKER_IMAGE_VICTORIAMETRICS}:${DOCKER_TAG_VICTORIAMETRICS:-$METRICS_VM_VERSION}" ;;
	prometheus) echo "${DOCKER_IMAGE_PROMETHEUS}:${DOCKER_TAG_PROMETHEUS:-$METRICS_PROM_VERSION}" ;;
	esac
}

# The argument vector of every compose call; callers wrap it in `run`
# (installer) or call it directly (ctl).
docker_compose_argv() {
	DOCKER_COMPOSE_ARGV=(docker compose -p "$DOCKER_PROJECT" -f "$(path_compose_yaml)")
}

docker_service_block() {
	local svc="$1" root="${DPISTACK_ROOT}"
	local common
	common=$(
		cat <<BLOCK
  ${svc}:
    image: $(docker_image "$svc")
    container_name: ${DOCKER_PROJECT}-${svc}
    restart: unless-stopped
    network_mode: host
BLOCK
	)
	case "$svc" in
	suricata)
		cat <<BLOCK
${common}
    cap_add: [NET_ADMIN, NET_RAW, SYS_NICE]
    command: ["--af-packet"]
    volumes:
      - ${root}/etc/suricata:/etc/suricata
      - ${root}/var/lib/suricata:/var/lib/suricata
      - ${root}/var/log/suricata:/var/log/suricata
      - ${root}/run/suricata:/var/run/suricata
BLOCK
		;;
	evebox)
		cat <<BLOCK
${common}
    command: ["server", "-c", "/etc/evebox/evebox.yaml"]
    volumes:
      - ${root}/etc/evebox:/etc/evebox:ro
      - ${root}/var/lib/evebox:/var/lib/evebox
      - ${root}/var/log/suricata:/var/log/suricata:ro
BLOCK
		;;
	redis)
		cat <<BLOCK
${common}
    command: ["redis-server", "--bind", "127.0.0.1", "--port", "6379"]
    volumes:
      - ${root}/var/lib/dpistack/redis:/data
BLOCK
		;;
	ntopng)
		cat <<BLOCK
${common}
    cap_add: [NET_ADMIN, NET_RAW]
    depends_on: [redis]
    command: ["/etc/ntopng/ntopng.conf"]
    volumes:
      - ${root}/etc/ntopng:/etc/ntopng:ro
      - ${root}/var/lib/ntopng:/var/lib/ntopng
BLOCK
		;;
	victoriametrics | prometheus)
		local data scrape token
		data=$(metrics_data_dir "$svc")
		scrape=$(path_scrape_yaml)
		token=$(path_metrics_token)
		# Same-path mounts: scrape.yaml names the token file by its host
		# path and works unchanged in the container. The container runs as
		# the dpistack-metrics user and the dpistack group, which is what
		# reads the token (root:dpistack 0640).
		local ids
		ids="$(id -u "$METRICS_USER" 2>/dev/null || echo 0):$(getent group dpistack 2>/dev/null | cut -d: -f3)"
		[[ "$ids" == *: ]] && ids="${ids}0"
		local cmd
		if [[ "$svc" == "victoriametrics" ]]; then
			cmd="[\"-storageDataPath=${data}\", \"-retentionPeriod=${CONF[METRICS_RETENTION]:-30d}\", \"-httpListenAddr=$(metrics_listen "$svc")\", \"-promscrape.config=${scrape}\"]"
		else
			cmd="[\"--config.file=${scrape}\", \"--storage.tsdb.path=${data}\", \"--storage.tsdb.retention.time=${CONF[METRICS_RETENTION]:-30d}\", \"--web.listen-address=$(metrics_listen "$svc")\"]"
		fi
		cat <<BLOCK
${common}
    user: "${ids}"
    command: ${cmd}
    volumes:
      - ${data}:${data}
      - ${scrape}:${scrape}:ro
      - ${token}:${token}:ro
BLOCK
		;;
	esac
}

docker_render_compose() {
	local svc blocks="" first=1
	for svc in $(docker_services); do
		((first)) || blocks+=$'\n'
		first=0
		blocks+="$(docker_service_block "$svc")"
	done
	render_template "$SCRIPT_DIR/templates/compose.yaml.tpl" "COMPOSE_SERVICES=${blocks}"
}

# docker_service_running <service> - the container is up.
docker_service_running() {
	local argv
	docker_compose_argv
	argv=("${DOCKER_COMPOSE_ARGV[@]}")
	"${argv[@]}" ps --status running --services 2>/dev/null | grep -qx -- "$1"
}

# docker_compose_current - compose.yaml on disk is what this config renders.
docker_compose_current() {
	local path
	path=$(path_compose_yaml)
	[[ -f "$path" ]] || return 1
	[[ "$(docker_render_compose | state_hash_content)" == "$(state_hash_content <"$path")" ]]
}

# docker_service_check <service> - rendered file current, container up.
docker_service_check() {
	command -v docker >/dev/null 2>&1 || return 1
	docker_compose_current || return 1
	docker_service_running "$1"
}

# docker_service_apply <service> - write the compose file, start the one
# service (compose starts what it depends on). The image is pulled by
# `up` when absent.
docker_service_apply() {
	local svc="$1"
	command -v docker >/dev/null 2>&1 || {
		echo "docker: не найден, нужен для ${svc} с RUNTIME=docker" >&2
		return 1
	}
	# Host directories the containers mount must exist, or Docker creates
	# them as root-owned and the services of the host cannot write there.
	local d
	for d in var/lib/suricata var/log/suricata run/suricata var/lib/evebox var/lib/dpistack/redis var/lib/ntopng etc/suricata etc/evebox etc/ntopng; do
		run mkdir -p "${DPISTACK_ROOT}/${d}" || return 1
	done
	write_rendered_file "$(path_compose_yaml)" "$(docker_render_compose)" || return 1
	docker_compose_argv
	run "${DOCKER_COMPOSE_ARGV[@]}" up -d "$svc"
}

# runtime_release_docker <service> - the service is going native: a container
# of it that is still up would hold the port. Without docker, a compose file
# or a running container there is nothing to do.
runtime_release_docker() {
	local svc="$1"
	command -v docker >/dev/null 2>&1 || return 0
	[[ -f "$(path_compose_yaml)" ]] || return 0
	docker_service_running "$svc" || return 0
	docker_compose_argv
	run "${DOCKER_COMPOSE_ARGV[@]}" rm -fsv "$svc"
}

# runtime_release_native <unit> - the service is going docker: the unit of
# the packaged one, if it is up, would hold the port the container needs.
runtime_release_native() {
	systemctl is-active --quiet "$1" 2>/dev/null || return 0
	run systemctl disable --now "$1"
}

docker_service_plan() {
	echo "$1: docker compose, образ $(docker_image "$1"), network_mode: host (рендер $(path_compose_yaml))"
}

# docker_suricata_test - suricata -T inside the image against the same
# files the service uses.
docker_suricata_test() {
	docker_compose_argv
	"${DOCKER_COMPOSE_ARGV[@]}" run --rm --no-deps suricata -T -c /etc/suricata/suricata.yaml -l /tmp
}

# docker_suricata_reload - reload rules through the socket in the container.
docker_suricata_reload() {
	docker_compose_argv
	"${DOCKER_COMPOSE_ARGV[@]}" exec -T suricata suricatasc -c ruleset-reload-nonblocking /var/run/suricata/suricata-command.socket
}

# docker_component_state <service> -> active|inactive|failed|absent, the
# same words systemd gives, for dpistack-ctl status. A container that is
# restarting counts as failed; one that exists but is not running, inactive.
docker_component_state() {
	local svc="$1" out
	command -v docker >/dev/null 2>&1 || {
		echo absent
		return
	}
	[[ -f "$(path_compose_yaml)" ]] || {
		echo absent
		return
	}
	docker_compose_argv
	out=$("${DOCKER_COMPOSE_ARGV[@]}" ps -a --format '{{.Service}} {{.State}}' 2>/dev/null)
	case "$(awk -v s="$svc" '$1 == s {print $2; exit}' <<<"$out")" in
	running) echo active ;;
	restarting) echo failed ;;
	"") echo absent ;;
	*) echo inactive ;;
	esac
}
