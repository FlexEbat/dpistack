#!/usr/bin/env bats
# Slice 35: a verb that changes something and is run by hand leaves a line in
# the audit log; reads and the panel's own calls do not.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	LOG="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	export MOCK_CALLS_LOG
	unset SUDO_USER SSH_CLIENT
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

@test "a change by hand is one line with the user, the verb, the target, the result and no password" {
	run "$CTL" panel-passwd <<<"a very secret phrase"
	[ "$status" -eq 0 ]
	[ "$(wc -l <"$LOG")" -eq 1 ]
	[ "$(jq -r .user "$LOG")" = "root" ]
	[ "$(jq -r .action "$LOG")" = "cli panel-passwd" ]
	[ "$(jq -r .result "$LOG")" = "ok" ]
	[ "$(jq -r .ts "$LOG" | cut -c11)" = "T" ]
	[ "$(grep -c 'a very secret phrase' "$LOG")" -eq 0 ]
	[ "$(stat -c %a "$LOG")" = "660" ]
}

@test "the user is the one who ran sudo and the address is the ssh client" {
	SUDO_USER=anna SSH_CLIENT="10.0.0.5 51234 22" run "$CTL" panel-passwd <<<"a very secret phrase"
	[ "$status" -eq 0 ]
	[ "$(jq -r .user "$LOG")" = "anna" ]
	[ "$(jq -r .ip "$LOG")" = "10.0.0.5" ]
}

@test "the panel's own calls (sudo as dpistack) are not logged twice" {
	SUDO_USER=dpistack run "$CTL" panel-passwd <<<"a very secret phrase"
	[ "$status" -eq 0 ]
	[ ! -e "$LOG" ]
}

@test "reads leave no line: users list, settings list, status" {
	"$CTL" panel-passwd <<<"a very secret phrase" >/dev/null
	before=$(wc -l <"$LOG")
	"$CTL" users list >/dev/null
	"$CTL" settings list --json >/dev/null 2>&1 || true
	"$CTL" version >/dev/null
	[ "$(wc -l <"$LOG")" -eq "$before" ]
}

@test "a refused change is logged as denied and an unknown target as error, with the exit code" {
	"$CTL" panel-passwd <<<"a very secret phrase" >/dev/null
	run "$CTL" users remove admin
	[ "$status" -eq 3 ]
	[ "$(tail -n 1 "$LOG" | jq -r .result)" = "denied" ]
	[[ "$(tail -n 1 "$LOG" | jq -r .detail)" == *"(exit 3)"* ]]
	run "$CTL" users passwd nobody <<<"another long phrase"
	[ "$status" -eq 4 ]
	[ "$(tail -n 1 "$LOG" | jq -r .result)" = "error" ]
	[ "$(tail -n 1 "$LOG" | jq -r .action)" = "cli users" ]
	[ "$(tail -n 1 "$LOG" | jq -r .target)" = "passwd" ]
}

@test "the value of KEY=VALUE is never written, only the key" {
	run "$CTL" settings set NTOPNG_PORT=34567
	[ "$(grep -c '34567' "$LOG")" -eq 0 ]
	[[ "$(tail -n 1 "$LOG" | jq -r .detail)" == *"NTOPNG_PORT=..."* ]]
}

@test "the exit code of the verb is the exit code of the command" {
	run "$CTL" users add
	[ "$status" -eq 2 ]
}
