#!/usr/bin/env bats
# heartbeat_start / heartbeat_stop (lib/common.sh): a line while a long build runs.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

hb() {
	bash -c '
		DRY_RUN="'"${DRY:-0}"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		'"$1"'
	'
}

@test "a long step gets a line at the interval and none after the stop" {
	DPISTACK_HEARTBEAT_SEC=1 run hb 'heartbeat_start "suricata build"; sleep 3.5; heartbeat_stop; sleep 1.5'
	[ "$status" -eq 0 ]
	[ "$(grep -c 'suricata build: still running' <<<"$output")" -ge 2 ]
	[ "$(grep -c 'suricata build: still running' <<<"$output")" -le 4 ]
	[[ "$output" == *"still running (1 s)"* ]]
}

@test "a step shorter than the interval prints nothing" {
	DPISTACK_HEARTBEAT_SEC=30 run hb 'heartbeat_start "x"; sleep 0.3; heartbeat_stop'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "a dry run starts no ticker, and stopping twice is harmless" {
	DRY=1 DPISTACK_HEARTBEAT_SEC=1 run hb 'heartbeat_start "x"; sleep 1.5; heartbeat_stop; heartbeat_stop'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "the source builds of Suricata and nDPI run under the heartbeat" {
	grep -q 'heartbeat_start "suricata build"' "$REPO_DIR/lib/step_suricata.sh"
	grep -q 'heartbeat_stop' "$REPO_DIR/lib/step_suricata.sh"
	grep -q 'heartbeat_start "ndpi build"' "$REPO_DIR/lib/step_ndpi.sh"
	grep -q 'heartbeat_stop' "$REPO_DIR/lib/step_ndpi.sh"
}
