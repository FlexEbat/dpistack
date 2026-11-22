#!/usr/bin/env bats
# scripts/ci-report.sh: what a failed CI job says about itself. The log is a
# sample of what scripts/gate.sh prints; gh is a fake that records the statuses.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	REPORT="$REPO_DIR/scripts/ci-report.sh"
	DIR="$(mktemp -d)"
	LOG="$DIR/gate.log"
	SUMMARY="$DIR/summary.md"
	GH_CALLS="$DIR/gh.calls"
	: >"$GH_CALLS"
	printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$GH_CALLS" >"$DIR/gh"
	chmod +x "$DIR/gh"
	PATH="$DIR:$PATH"
	export GITHUB_STEP_SUMMARY="$SUMMARY" PATH
	unset GH_TOKEN GITHUB_SHA GITHUB_REPOSITORY
}

teardown() { rm -rf "$DIR"; }

sample_bats_log() {
	cat >"$LOG" <<'LOG'
== bats ==
ok 128 some test
not ok 130 no test has a bare '! command' before its last line (R138)
# (in test file tests/ci_config.bats, line 90)
#   `[ "$n" -eq 0 ]' failed
# tests/detect_notify.bats:168
ok 131 another one
not ok 132 second failure
# expected 1 got 2
LOG
}

@test "a bats failure is an annotation with its reason, and the summary lists it" {
	sample_bats_log
	run "$REPORT" "$LOG" "bats shard 4"
	[ "$status" -eq 0 ]
	[[ "$output" == *"::error title=bats shard 4 #1::not ok 130 no test has a bare '! command' before its last line (R138)%0A(in test file tests/ci_config.bats, line 90)"* ]]
	[[ "$output" == *"::error title=bats shard 4 #2::not ok 132 second failure%0Aexpected 1 got 2"* ]]
	[[ "$output" != *"some test"* ]]
	grep -q '### bats shard 4: 2 failure(s)' "$SUMMARY"
	grep -q 'expected 1 got 2' "$SUMMARY"
}

@test "a gate stage, a Go test and a panic are failures too" {
	printf '== shellcheck ==\nFAIL: shellcheck\n--- FAIL: TestX (0.00s)\nFAIL\tgithub.com/x/y\t0.1s\npanic: boom\n' >"$LOG"
	run "$REPORT" "$LOG" checks
	[ "$(grep -c '^::error' <<<"$output")" -eq 4 ]
	[[ "$output" == *"::error title=checks #1::FAIL: shellcheck"* ]]
	[[ "$output" == *"::error title=checks #4::panic: boom"* ]]
}

@test "a log with no failure line reports its last lines, never silence" {
	printf 'line one\nE: Failed to fetch http://archive.ubuntu.com/x\nline three\n' >"$LOG"
	run "$REPORT" "$LOG" checks
	[ "$status" -eq 0 ]
	[[ "$output" == *"::error title=checks #1::the job failed without a test or a check naming itself"* ]]
	[[ "$output" == *"Failed to fetch"* ]]
	grep -q 'Failed to fetch' "$SUMMARY"
}

@test "at most 10 annotations and 6 statuses, with a warning that says where the rest is" {
	local i
	for i in $(seq 1 14); do printf 'not ok %s t%s\n# why %s\n' "$i" "$i" "$i"; done >"$LOG"
	GH_TOKEN=x GITHUB_SHA=abc GITHUB_REPOSITORY=o/r run "$REPORT" "$LOG" "bats shard 1"
	[ "$(grep -c '^::error' <<<"$output")" -eq 10 ]
	[[ "$output" == *"::warning title=bats shard 1::14 failures, the first 10 are annotated"* ]]
	[ "$(wc -l <"$GH_CALLS")" -eq 6 ]
	[ "$(grep -c '^\*\*not ok' "$SUMMARY")" -eq 14 ]
}

@test "a status names the test and the first line of its reason, within 130 characters" {
	printf 'not ok 7 a very long name %s\n# the reason line\n' "$(printf 'x%.0s' $(seq 1 200))" >"$LOG"
	GH_TOKEN=x GITHUB_SHA=abc GITHUB_REPOSITORY=o/r run "$REPORT" "$LOG" "bats shard 2"
	grep -q 'statuses/abc' "$GH_CALLS"
	grep -q 'context=bats shard 2 #1' "$GH_CALLS"
	local desc
	desc=$(sed -n 's/.*description=//p' "$GH_CALLS")
	[ "${#desc}" -le 130 ]
}

@test "a failing gh does not make the report fail" {
	printf '#!/usr/bin/env bash\nexit 1\n' >"$DIR/gh"
	sample_bats_log
	GH_TOKEN=x GITHUB_SHA=abc GITHUB_REPOSITORY=o/r run "$REPORT" "$LOG" "bats shard 1"
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not post the status"* ]]
}

@test "newlines and percent signs in a message are escaped for the workflow command" {
	printf 'not ok 1 100%% done\n# a\n# b\n' >"$LOG"
	run "$REPORT" "$LOG" x
	[[ "$output" == *"100%25 done%0Aa%0Ab"* ]]
}

@test "a missing log is exit 2 with a message" {
	run "$REPORT" "$DIR/none.log" x
	[ "$status" -eq 2 ]
	[[ "$output" == *"no log to read"* ]]
}
