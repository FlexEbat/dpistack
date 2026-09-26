#!/usr/bin/env bash
# Native (systemd) runtime. Steps call rt_start/rt_stop/rt_exec, never
# systemctl directly (tech.md section 3). Slice 1 only needs the
# dispatch point to exist; components wire real units in their slice.

rt_native_start() { run systemctl start "$1"; }
rt_native_stop() { run systemctl stop "$1"; }
rt_native_restart() { run systemctl restart "$1"; }
rt_native_exec() {
	local unit="$1"
	shift
	run systemctl "$@" "$unit"
}
