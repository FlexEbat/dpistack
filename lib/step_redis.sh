#!/usr/bin/env bash
# Redis: ntopng's own state/preferences store (admin password hash,
# host stats cache), independent of any EVE_REDIS suricata setting
# (tech.md slice 5). Plain distro package, default config, always on.

REDIS_PACKAGE="redis-server"
REDIS_UNIT="redis-server.service"

REDIS_STATE_KEY="step.redis.status"

step_redis_check() {
	command -v redis-server >/dev/null 2>&1 || return 1
	systemctl is-active --quiet "$REDIS_UNIT" || return 1
	[[ "$(state_read_value "$REDIS_STATE_KEY")" == "done" ]] || return 1
	return 0
}

step_redis_apply() {
	if ! command -v redis-server >/dev/null 2>&1; then
		pkg_install "$REDIS_PACKAGE" || return 1
	fi
	run systemctl enable --now "$REDIS_UNIT" || return 1
	state_write_value "$REDIS_STATE_KEY" "done"
	return 0
}

step_redis_plan() {
	echo "redis: установка $REDIS_PACKAGE, systemctl enable --now $REDIS_UNIT"
}
