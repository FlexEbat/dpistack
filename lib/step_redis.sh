#!/usr/bin/env bash
# Redis: ntopng's own state/preferences store (admin password hash,
# host stats cache), independent of any EVE_REDIS suricata setting
# (tech.md slice 5). Plain distro package, default config, always on.

REDIS_PACKAGE="redis-server"
REDIS_UNIT="redis-server.service"

REDIS_STATE_KEY="step.redis.status"

step_redis_check() {
	docker_wanted redis && {
		docker_service_check redis
		return
	}
	command -v redis-server >/dev/null 2>&1 || return 1
	systemctl is-active --quiet "$REDIS_UNIT" || return 1
	[[ "$(state_read_value "$REDIS_STATE_KEY")" == "done" ]] || return 1
	return 0
}

step_redis_apply() {
	if docker_wanted redis; then
		runtime_release_native "$REDIS_UNIT" || return 1
		docker_service_apply redis || return 1
		state_write_value "$REDIS_STATE_KEY" "done"
		return 0
	fi
	runtime_release_docker redis || return 1
	if ! command -v redis-server >/dev/null 2>&1; then
		pkg_install "$REDIS_PACKAGE" || return 1
	fi
	run systemctl enable --now "$REDIS_UNIT" || return 1
	state_write_value "$REDIS_STATE_KEY" "done"
	return 0
}

step_redis_plan() {
	docker_wanted redis && {
		docker_service_plan redis
		return 0
	}
	echo "redis: installing $REDIS_PACKAGE, systemctl enable --now $REDIS_UNIT"
}
