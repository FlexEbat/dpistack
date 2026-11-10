#!/usr/bin/env bats
# Slice 43 (18.43), the Alert Center: `alerts list|history|ack|snooze|resolve|reopen`.
# Time is fixed with DPISTACK_NOW_CMD, so snoozes and expiry are exact.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	STATE_DIR="$DPISTACK_ROOT/var/lib/dpistack"
	HEALTH="$STATE_DIR/health.json"
	EVENTS="$STATE_DIR/events.jsonl"
	STATE="$STATE_DIR/alerts-state.json"
	AUDIT="$STATE_DIR/audit/audit.jsonl"
	EVE="$DPISTACK_ROOT/var/log/suricata/eve.json"
	mkdir -p "$(dirname "$EVE")"
	NOW_FILE="$(mktemp)"
	NOW_CMD="$(mktemp)"
	printf '#!/bin/sh\ncat "%s"\n' "$NOW_FILE" >"$NOW_CMD"
	chmod +x "$NOW_CMD"
	DPISTACK_NOW_CMD="$NOW_CMD"
	export DPISTACK_NOW_CMD
	set_now 1767225600 # 2026-01-01T00:00:00Z
	rm -f "$AUDIT"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG" "$NOW_FILE" "$NOW_CMD"
}

set_now() { echo "$1" >"$NOW_FILE"; }

# health <id:status:since>... - a health.json with these checks.
health() {
	local items=() spec id st since
	for spec in "$@"; do
		IFS=: read -r id st since <<<"$spec"
		since="${since:-2025-12-31T23:00:00Z}"
		# the time has colons: put them back
		items+=("$(jq -nc --arg id "$id" --arg st "$st" --arg since "${spec#*:*:}" '{id:$id,status:$st,value:"v",detail:"d",since:$since}')")
	done
	printf '%s\n' "${items[@]}" | jq -sc '{ts:"2026-01-01T00:00:00Z",overall:"warn",checks:.}' >"$HEALTH"
}

# eve <sid> <severity> <timestamp> [msg] - append one Suricata alert.
eve() {
	printf '{"timestamp":"%s","event_type":"alert","alert":{"signature_id":%s,"severity":%s,"signature":"%s","category":"Cat"}}\n' \
		"$3" "$1" "$2" "${4:-sig $1}" >>"$EVE"
}

list() { "$CTL" alerts list --json "$@"; }

@test "alerts list: nothing wrong gives an empty list and zero counts" {
	run list
	[ "$status" -eq 0 ]
	[ "$(jq -r '.alerts | length' <<<"$output")" = 0 ]
	[ "$(jq -c .counts <<<"$output")" = '{"new":0,"acknowledged":0,"snoozed":0,"resolved":0,"new_crit":0}' ]
}

@test "alerts list: only warn and crit checks are alerts, crit first, as new" {
	health "suricata.process:ok:2025-12-31T20:00:00Z" "rules.age:warn:2025-12-31T21:00:00Z" "disk.free:crit:2025-12-31T22:00:00Z"
	run list
	[ "$status" -eq 0 ]
	[ "$(jq -r '[.alerts[].key] | join(",")' <<<"$output")" = "watch:disk.free,watch:rules.age" ]
	[ "$(jq -r '.alerts[0] | [.source, .severity, .state, .first_seen] | join(" ")' <<<"$output")" = "watchdog crit new 2025-12-31T22:00:00Z" ]
	[ "$(jq -r .counts.new_crit <<<"$output")" = 1 ]
}

@test "alerts list: Suricata alerts are grouped by rule with severity, count and times" {
	eve 100 1 "2026-01-01T00:00:10.000000+0000" "ET one"
	eve 100 1 "2026-01-01T00:00:30.000000+0000" "ET one"
	eve 100 1 "2026-01-01T00:00:20.000000+0000" "ET one"
	eve 200 2 "2026-01-01T00:00:05.000000+0000" "ET two"
	eve 300 3 "2026-01-01T00:00:06.000000+0000" "ET three"
	run list
	[ "$(jq -r '.alerts | length' <<<"$output")" = 3 ]
	[ "$(jq -r '.alerts[] | select(.key=="sid:100") | [.severity, .count, .first_seen, .last_seen, .title] | join("|")' <<<"$output")" = "crit|3|2026-01-01T00:00:10.000000+0000|2026-01-01T00:00:30.000000+0000|ET one" ]
	[ "$(jq -r '.alerts[] | select(.key=="sid:200") | .severity' <<<"$output")" = warn ]
	[ "$(jq -r '.alerts[] | select(.key=="sid:300") | .severity' <<<"$output")" = info ]
}

@test "alerts list: a broken line in eve.json does not hide the other alerts" {
	echo '{"timestamp":"2026-01-01T00:00:01.000000+0000","event_type":"alert","alert":{"signature_id":9' >"$EVE"
	eve 100 1 "2026-01-01T00:00:10.000000+0000"
	run list
	[ "$status" -eq 0 ]
	[ "$(jq -r '.alerts | length' <<<"$output")" = 1 ]
}

@test "alerts ack: the state is acknowledged, by whom and why, and it is listed" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	run "$CTL" alerts ack watch:disk.free --note "ticket 42" --by admin
	[ "$status" -eq 0 ]
	run list
	[ "$(jq -r '.alerts[0] | [.state, .by, .note] | join("|")' <<<"$output")" = "acknowledged|admin|ticket 42" ]
	[ "$(jq -r .counts.acknowledged <<<"$output")" = 1 ]
	[ "$(jq -r .counts.new <<<"$output")" = 0 ]
	[ "$(stat -c %a "$STATE")" = 644 ]
	jq -e '.version == 1' "$STATE"
}

@test "alerts snooze: hidden until the time, then new again" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	run "$CTL" alerts snooze watch:disk.free --for 1h --by admin
	[ "$status" -eq 0 ]
	run list
	[ "$(jq -r '.alerts[0].state' <<<"$output")" = snoozed ]
	[ "$(jq -r '.alerts[0].until' <<<"$output")" = 1767229200 ]
	set_now 1767229199
	[ "$(list | jq -r '.alerts[0].state')" = snoozed ]
	set_now 1767229200
	[ "$(list | jq -r '.alerts[0].state')" = new ]
}

@test "alerts snooze: the durations are 1h, 4h, 24h, 7d and nothing else" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	for d in 4h 24h 7d; do
		run "$CTL" alerts snooze watch:disk.free --for "$d"
		[ "$status" -eq 0 ]
	done
	for d in 5h 1 "" 30d; do
		run "$CTL" alerts snooze watch:disk.free --for "$d"
		[ "$status" -eq 5 ]
	done
	run "$CTL" alerts snooze watch:disk.free
	[ "$status" -eq 5 ]
	run "$CTL" alerts ack watch:disk.free --for 1h
	[ "$status" -eq 5 ]
}

@test "alerts resolve: a Suricata alert stays resolved until a newer event, a watchdog alert until the status changes" {
	eve 100 1 "2025-12-31T23:59:00.000000+0000"
	health "disk.free:crit:2025-12-31T22:00:00Z"
	"$CTL" alerts resolve sid:100 --by admin
	"$CTL" alerts resolve watch:disk.free --by admin
	run list
	[ "$(jq -r '[.alerts[].state] | unique | join(",")' <<<"$output")" = resolved ]
	eve 100 1 "2026-01-01T00:05:00.000000+0000"
	health "disk.free:warn:2026-01-01T00:04:00Z"
	run list
	[ "$(jq -r '.alerts[] | select(.key=="sid:100") | .state' <<<"$output")" = new ]
	[ "$(jq -r '.alerts[] | select(.key=="watch:disk.free") | .state' <<<"$output")" = new ]
}

@test "alerts: an acknowledged alert that cleared is listed as resolved and cleared" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	"$CTL" alerts ack watch:disk.free --by admin
	health "disk.free:ok:2026-01-01T00:00:00Z"
	run list
	[ "$(jq -r '.alerts[0] | [.key, .state, .cleared, .by, .title] | join("|")' <<<"$output")" = "watch:disk.free|resolved|true|admin|disk.free" ]
}

@test "alerts reopen: the decision is dropped and the alert is new" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	"$CTL" alerts ack watch:disk.free --by admin
	run "$CTL" alerts reopen watch:disk.free --by admin
	[ "$status" -eq 0 ]
	[ "$(list | jq -r '.alerts[0].state')" = new ]
	[ "$(jq -r '.alerts | length' "$STATE")" = 0 ]
}

@test "alerts: unknown alerts and bad arguments are refused" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	run "$CTL" alerts ack watch:nothing
	[ "$status" -eq 5 ]
	run "$CTL" alerts ack "../x"
	[ "$status" -eq 5 ]
	run "$CTL" alerts ack 'sid:1;rm'
	[ "$status" -eq 5 ]
	run "$CTL" alerts ack watch:disk.free --note 'a"b'
	[ "$status" -eq 5 ]
	run "$CTL" alerts ack watch:disk.free --by 'a b'
	[ "$status" -eq 5 ]
	run "$CTL" alerts ack
	[ "$status" -eq 2 ]
	run "$CTL" alerts ack watch:disk.free --bogus
	[ "$status" -eq 2 ]
	run "$CTL" alerts frobnicate
	[ "$status" -eq 2 ]
	[ ! -e "$STATE" ]
}

@test "alerts list: the filters, and a bad filter value" {
	health "disk.free:crit:2025-12-31T22:00:00Z" "rules.age:warn:2025-12-31T22:00:00Z"
	eve 100 3 "2026-01-01T00:00:10.000000+0000"
	"$CTL" alerts ack watch:rules.age --by admin
	[ "$(list --state new | jq -r '[.alerts[].key] | sort | join(",")')" = "sid:100,watch:disk.free" ]
	[ "$(list --source suricata | jq -r '[.alerts[].key] | join(",")')" = "sid:100" ]
	[ "$(list --severity warn | jq -r '[.alerts[].key] | join(",")')" = "watch:rules.age" ]
	[ "$(list --state new --source watchdog | jq -r '[.alerts[].key] | join(",")')" = "watch:disk.free" ]
	# the counts are of everything, not of the filter
	[ "$(list --source suricata | jq -r '.counts.acknowledged')" = 1 ]
	run list --state bogus
	[ "$status" -eq 5 ]
	run list --source bogus
	[ "$status" -eq 5 ]
	run list --severity bogus
	[ "$status" -eq 5 ]
}

@test "alerts list: the plain text names the counts and each alert" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	run "$CTL" alerts list
	[ "$status" -eq 0 ]
	[[ "$output" == *"1 new (1 critical)"* && "$output" == *"[new] crit watch:disk.free"* ]]
}

@test "alerts history: people's actions and the watchdog's changes, newest first, limited" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	printf '{"ts":"2025-12-31T22:00:00Z","check":"disk.free","from":"ok","to":"crit","detail":"free 2%%"}\n' >"$EVENTS"
	set_now 1767225700
	"$CTL" alerts ack watch:disk.free --by admin --note seen
	set_now 1767225800
	"$CTL" alerts snooze watch:disk.free --for 4h --by admin
	run "$CTL" alerts history --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '[.history[] | .kind + ":" + .action] | join(",")' <<<"$output")" = "action:snooze,action:ack,event:status" ]
	[ "$(jq -r '.history[2].detail' <<<"$output")" = "ok to crit: free 2%" ]
	[ "$("$CTL" alerts history --json --limit 1 | jq -r '.history | length')" = 1 ]
	run "$CTL" alerts history --limit 0
	[ "$status" -eq 5 ]
	run "$CTL" alerts history --limit 501
	[ "$status" -eq 5 ]
	run "$CTL" alerts history
	[[ "$output" == *"action ack"* || "$output" == *"action watch:disk.free ack"* ]]
}

@test "alerts: the history is kept to 500 entries and old resolved decisions are dropped" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	jq -nc '{version:1, alerts:{"sid:7":{state:"resolved",at:"2025-11-01T00:00:00Z",by:"a",note:"",until:null,source:"suricata",severity:"warn",title:"old",detail:"",first_seen:"x",last_seen:"x",count:1}},
		history:[range(0;505) | {ts:"2025-12-01T00:00:00Z",key:"sid:7",action:"ack",by:"a",note:"",title:"old"}]}' >"$STATE"
	"$CTL" alerts ack watch:disk.free --by admin
	[ "$(jq -r '.history | length' "$STATE")" = 500 ]
	[ "$(jq -r '.history[-1].key' "$STATE")" = watch:disk.free ]
	[ "$(jq -r '.alerts | keys | join(",")' "$STATE")" = watch:disk.free ]
}

@test "alerts: a damaged state file counts as empty and the next action rewrites it" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	echo 'not json' >"$STATE"
	run list
	[ "$status" -eq 0 ]
	[ "$(jq -r '.alerts[0].state' <<<"$output")" = new ]
	run "$CTL" alerts ack watch:disk.free --by admin
	[ "$status" -eq 0 ]
	jq -e '.alerts["watch:disk.free"].state == "acknowledged"' "$STATE"
}

@test "alerts: two actions at once both land" {
	health "disk.free:crit:2025-12-31T22:00:00Z" "rules.age:warn:2025-12-31T22:00:00Z"
	"$CTL" alerts ack watch:disk.free --by a &
	"$CTL" alerts ack watch:rules.age --by b &
	wait
	[ "$(jq -r '.alerts | keys | join(",")' "$STATE")" = "watch:disk.free,watch:rules.age" ]
	[ "$(jq -r '.history | length' "$STATE")" = 2 ]
}

@test "alerts: changing a state is audited, reading is not" {
	health "disk.free:crit:2025-12-31T22:00:00Z"
	"$CTL" alerts list >/dev/null
	"$CTL" alerts history >/dev/null
	[ ! -s "$AUDIT" ]
	"$CTL" alerts ack watch:disk.free --by admin
	[ "$(wc -l <"$AUDIT")" = 1 ]
	[ "$(jq -r .action "$AUDIT")" = "cli alerts" ]
	[ "$(jq -r .target "$AUDIT")" = ack ]
}
