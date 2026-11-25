#!/usr/bin/env bats
# Task 61: `dpistack report daily|weekly` and `dpistack devices` read the day
# files the watchdog wrote (tests/history.bats checks the writing).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/var/lib/dpistack/history"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	H="$DPISTACK_ROOT/var/lib/dpistack/history"
	export DPISTACK_NOW=1790000000 # 2026-09-21
	cat >"$H/2026-09-20.json" <<'J'
{"date":"2026-09-20","flows":3,"bytes":3000,"apps":{"tls":{"flows":2,"bytes":2500},"http":{"flows":1,"bytes":500}},
 "devices":{"10.0.0.5":{"flows":3,"bytes":3000,"apps":{"tls":2,"http":1}}},
 "alerts":{"2000001":{"count":2,"msg":"ET P2P BitTorrent","severity":2}}}
J
	cat >"$H/2026-09-21.json" <<'J'
{"date":"2026-09-21","flows":2,"bytes":9000,"apps":{"tls":{"flows":1,"bytes":8000},"quic":{"flows":1,"bytes":1000}},
 "devices":{"10.0.0.5":{"flows":1,"bytes":8000,"apps":{"tls":1}},"192.168.1.20":{"flows":1,"bytes":1000,"apps":{"quic":1}}},
 "alerts":{"2000001":{"count":1,"msg":"ET P2P BitTorrent","severity":2},"2000002":{"count":4,"msg":"ET POLICY test","severity":3}}}
J
	echo '{"10.0.0.5":{"first":"2026-09-01","last":"2026-09-21"},"192.168.1.20":{"first":"2026-09-21","last":"2026-09-21"}}' >"$DPISTACK_ROOT/var/lib/dpistack/devices.json"
}

teardown() { rm -rf "$DPISTACK_ROOT"; }

@test "daily --json adds one day up: totals, top applications and devices by traffic, alerts by count" {
	run "$CTL" report daily --date 2026-09-21 --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .flows <<<"$output")" -eq 2 ]
	[ "$(jq -r .bytes <<<"$output")" -eq 9000 ]
	[ "$(jq -r '.apps[0].app' <<<"$output")" = "tls" ]
	[ "$(jq -r '.devices[0].ip' <<<"$output")" = "10.0.0.5" ]
	[ "$(jq -r '.devices[0].top_app' <<<"$output")" = "tls" ]
	[ "$(jq -r '.alerts[0].sid' <<<"$output")" -eq 2000002 ]
	[ "$(jq -r '.alerts[0].count' <<<"$output")" -eq 4 ]
	[ "$(jq -r '.new_devices | join(",")' <<<"$output")" = "192.168.1.20" ]
}

@test "weekly adds the seven days ending at the date, days without a file are just not there" {
	run "$CTL" report weekly --date 2026-09-21 --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .from <<<"$output")" = "2026-09-15" ]
	[ "$(jq -r '.days | join(",")' <<<"$output")" = "2026-09-20,2026-09-21" ]
	[ "$(jq -r .flows <<<"$output")" -eq 5 ]
	[ "$(jq -r .bytes <<<"$output")" -eq 12000 ]
	[ "$(jq -r '.apps[] | select(.app == "tls") | .bytes' <<<"$output")" -eq 10500 ]
	[ "$(jq -r '.devices[] | select(.ip == "10.0.0.5") | .flows' <<<"$output")" -eq 4 ]
	[ "$(jq -r '.alerts[] | select(.sid == 2000001) | .count' <<<"$output")" -eq 3 ]
	# 10.0.0.5 was first seen before the week, so only the other one is new
	[ "$(jq -r '.new_devices | join(",")' <<<"$output")" = "192.168.1.20" ]
}

@test "the date defaults to today (UTC) and the plain text reads well" {
	run "$CTL" report daily
	[ "$status" -eq 0 ]
	[[ "$output" == *"daily report 2026-09-21 to 2026-09-21"* ]]
	[[ "$output" == *"flows: 2, traffic: 8.7 KiB"* ]]
	[[ "$output" == *"  tls  1 flows  7.8 KiB"* ]]
	[[ "$output" == *"  10.0.0.5  1 flows  7.8 KiB  mostly tls"* ]]
	[[ "$output" == *"sid 2000002  x4  severity 3  ET POLICY test"* ]]
	[[ "$output" == *"new devices: 192.168.1.20"* ]]
}

@test "a range with no history says why instead of printing zeros" {
	run "$CTL" report daily --date 2026-01-01
	[ "$status" -eq 0 ]
	[[ "$output" == *"history is off: set HISTORY_ENABLE=yes"* ]]
	[ "$(jq -r .enabled < <("$CTL" report daily --date 2026-01-01 --json))" = "false" ]
	printf 'HISTORY_ENABLE=yes\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" report daily --date 2026-01-01
	[[ "$output" == *"the watchdog has not seen traffic yet"* ]]
	[ "$(jq -r .enabled < <("$CTL" report daily --date 2026-01-01 --json))" = "true" ]
	rm -rf "$H"
	run "$CTL" report weekly --json
	[ "$(jq -r '.days | length' <<<"$output")" -eq 0 ]
}

@test "only ten of each are listed, the biggest first" {
	local i apps='{}'
	for i in $(seq 1 14); do apps=$(jq -c --arg a "app$i" --argjson b "$((i * 100))" '.[$a] = {flows: 1, bytes: $b}' <<<"$apps"); done
	jq -nc --argjson apps "$apps" '{date:"2026-09-19",flows:14,bytes:10500,apps:$apps,devices:{},alerts:{}}' >"$H/2026-09-19.json"
	run "$CTL" report daily --date 2026-09-19 --json
	[ "$(jq -r '.apps | length' <<<"$output")" -eq 10 ]
	[ "$(jq -r '.apps[0].app' <<<"$output")" = "app14" ]
}

@test "bad dates and options are refused: exit 5 for a date, 2 for the rest" {
	run "$CTL" report daily --date 2026-13-40
	[ "$status" -eq 5 ]
	run "$CTL" report daily --date yesterday
	[ "$status" -eq 5 ]
	run "$CTL" report monthly
	[ "$status" -eq 2 ]
	run "$CTL" report
	[ "$status" -eq 2 ]
	run "$CTL" report daily --nonsense
	[ "$status" -eq 2 ]
	run "$CTL" report daily --date
	[ "$status" -eq 2 ]
}

@test "devices lists the private addresses, the one seen last first" {
	run "$CTL" devices
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "192.168.1.20  first seen 2026-09-21  last seen 2026-09-21" ]
	[ "${lines[1]}" = "10.0.0.5  first seen 2026-09-01  last seen 2026-09-21" ]
	run "$CTL" devices --json
	[ "$(jq -r 'length' <<<"$output")" -eq 2 ]
	[ "$(jq -r '.[0].last' <<<"$output")" = "2026-09-21" ]
	rm "$DPISTACK_ROOT/var/lib/dpistack/devices.json"
	run "$CTL" devices
	[[ "$output" == *"no device recorded yet"* ]]
	run "$CTL" devices --json
	[ "$output" = "[]" ]
	run "$CTL" devices bogus
	[ "$status" -eq 2 ]
}
