#!/usr/bin/env bash
# Docker runtime. Steps call rt_start/rt_stop/rt_exec, never docker or
# compose directly (tech.md section 3). Not wired to any real compose
# file yet: docker runtimes are rejected as "пока не поддерживается"
# in lib/schema.sh until the slice that implements them.

rt_docker_start() { run docker compose -f "$(path_compose_yaml)" up -d "$1"; }
rt_docker_stop() { run docker compose -f "$(path_compose_yaml)" stop "$1"; }
rt_docker_restart() { run docker compose -f "$(path_compose_yaml)" restart "$1"; }
rt_docker_exec() {
	local svc="$1"
	shift
	run docker compose -f "$(path_compose_yaml)" exec "$svc" "$@"
}
