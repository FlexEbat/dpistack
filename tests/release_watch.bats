#!/usr/bin/env bats
# The automatic check of Suricata releases: scripts/check-suricata-release.sh
# reads the tags, scripts/suricata-watch.sh builds and reports in issues.
# The network, the build and gh are replaced by stubs.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WORK="$(mktemp -d)"
	CALLS="$WORK/calls"
	: >"$CALLS"
	export CALLS
	current="$(sed -n 's/^SURICATA_STABLE_REF="\(suricata-[0-9.]*\)"$/\1/p' "$REPO_DIR/lib/step_suricata.sh")"
	series="${current%.*}"
	export current series
}

teardown() {
	rm -rf "$WORK"
}

# check_with <tag>... - run the release check on a fixed list of tags.
check_with() {
	printf '%s\n' "$@" >"$WORK/tags"
	SURICATA_TAGS_FILE="$WORK/tags" run bash "$REPO_DIR/scripts/check-suricata-release.sh"
}

@test "the pin is a final release of a numbered series" {
	[[ "$current" =~ ^suricata-[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "release check: the pinned release is the newest one" {
	check_with "$current" "$series.0" "suricata-7.0.99"
	[ "$status" -eq 0 ]
	[[ "$output" == *"status=up-to-date"* ]]
	[[ "$output" == *"latest=$current"* ]]
	[[ "$output" == *"newer_series="$'\n'"status=up-to-date"* ]]
}

@test "release check: a newer release of the same series is an update" {
	check_with "$current" "$series.999" "$series.998"
	[[ "$output" == *"status=update"* ]]
	[[ "$output" == *"latest=$series.999"* ]]
}

@test "release check: versions sort numerically, not as text" {
	check_with "$current" "$series.9" "$series.1000"
	[[ "$output" == *"latest=$series.1000"* ]]
}

@test "release check: candidates, betas and dev tags are not releases" {
	check_with "$current" "$series.999-rc1" "$series.999-beta2" "suricata-99.0.0-dev" "suricata-99.0.0-rc1" "suricata-$series.999"
	[[ "$output" == *"status=up-to-date"* ]]
	[[ "$output" == *"latest=$current"* ]]
	[[ "$output" == *"newer_series="$'\n'"status"* ]]
}

@test "release check: a newer series is reported apart from the update" {
	check_with "$current" "suricata-99.0.0"
	[[ "$output" == *"status=up-to-date"* ]]
	[[ "$output" == *"newer_series=suricata-99.0.0"* ]]
}

@test "release check: an older series is not news" {
	check_with "$current" "suricata-1.0.0"
	[[ "$output" == *"newer_series="$'\n'* ]]
}

@test "release check: a pin newer than every tag is reported as ahead" {
	check_with "$series.0" "$series.1"
	[ "$status" -eq 0 ]
	if [ "$current" != "$series.1" ]; then
		[[ "$output" == *"status=ahead"* ]]
	fi
}

@test "release check: no tags is unknown, with a failing status" {
	: >"$WORK/tags"
	SURICATA_TAGS_FILE="$WORK/tags" run bash "$REPO_DIR/scripts/check-suricata-release.sh"
	[ "$status" -eq 2 ]
	[[ "$output" == *"status=unknown"* ]]
}

# watch_with <check output> - run the watcher with stubs. FAKE_BUILD_FAIL
# lists the tags whose build fails, FAKE_GH_OPEN=1 pretends an issue is open.
watch_with() {
	printf '#!/usr/bin/env bash\ncat <<EOF\n%s\nEOF\n' "$1" >"$WORK/check"
	cat >"$WORK/build" <<'EOF'
#!/usr/bin/env bash
echo "build $1" >>"$CALLS"
[[ " ${FAKE_BUILD_FAIL:-} " == *" $1 "* ]] && exit 1
exit 0
EOF
	cat >"$WORK/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$CALLS"
if [[ "$1 $2" == "issue list" ]]; then echo "${FAKE_GH_OPEN:-0}"; fi
exit 0
EOF
	chmod +x "$WORK/check" "$WORK/build" "$WORK/gh"
	SURICATA_RELEASE_CHECK="$WORK/check" SURICATA_BUILD_CHECK="$WORK/build" GH="$WORK/gh" \
		run bash "$REPO_DIR/scripts/suricata-watch.sh"
}

up_to_date() { printf 'current=suricata-8.0.7\nlatest=suricata-8.0.7\nnewest=suricata-8.0.7\nnewer_series=\nstatus=up-to-date'; }
has_update() { printf 'current=suricata-8.0.7\nlatest=suricata-8.0.9\nnewest=suricata-8.0.9\nnewer_series=\nstatus=update'; }

@test "watch: nothing new and the pin builds, no issue" {
	watch_with "$(up_to_date)"
	[ "$status" -eq 0 ]
	[ "$(grep -c '^build ' "$CALLS")" = "1" ]
	grep -q '^build suricata-8.0.7$' "$CALLS"
	run grep -c 'issue create' "$CALLS"
	[ "$output" = "0" ]
}

@test "watch: a newer release that builds is reported as tested" {
	watch_with "$(has_update)"
	[ "$status" -eq 0 ]
	grep -q '^build suricata-8.0.9$' "$CALLS"
	grep -q 'issue create --title Suricata suricata-8.0.9 проверен: поднять SURICATA_STABLE_REF' "$CALLS"
}

@test "watch: a newer release that does not build is reported, the pin stays" {
	FAKE_BUILD_FAIL="suricata-8.0.9" watch_with "$(has_update)"
	[ "$status" -eq 0 ]
	grep -q 'issue create --title Suricata suricata-8.0.9 не прошёл проверку сборки' "$CALLS"
	run grep -c 'проверен: поднять' "$CALLS"
	[ "$output" = "0" ]
}

@test "watch: a pinned release that stops building fails the run and opens an issue" {
	FAKE_BUILD_FAIL="suricata-8.0.7" watch_with "$(up_to_date)"
	[ "$status" -eq 1 ]
	grep -q 'issue create --title Suricata suricata-8.0.7 (SURICATA_STABLE_REF) больше не собирается' "$CALLS"
}

@test "watch: an issue that is already open is not opened twice" {
	FAKE_GH_OPEN=1 FAKE_BUILD_FAIL="suricata-8.0.9" watch_with "$(has_update)"
	[ "$status" -eq 0 ]
	run grep -c 'issue create' "$CALLS"
	[ "$output" = "0" ]
}

@test "watch: a newer series is announced" {
	watch_with "$(printf 'current=suricata-8.0.7\nlatest=suricata-8.0.7\nnewest=suricata-9.0.0\nnewer_series=suricata-9.0.0\nstatus=up-to-date')"
	[ "$status" -eq 0 ]
	grep -q 'issue create --title Вышла новая серия Suricata: suricata-9.0.0' "$CALLS"
}

@test "watch: no answer from the release check builds nothing and fails" {
	watch_with "status=unknown"
	[ "$status" -eq 1 ]
	run grep -c '^build ' "$CALLS"
	[ "$output" = "0" ]
}

@test "the weekly workflow runs the watcher with least privilege and a pinned checkout" {
	wf="$REPO_DIR/.github/workflows/suricata-watch.yml"
	grep -q 'cron:' "$wf"
	grep -q 'workflow_dispatch' "$wf"
	grep -q 'scripts/suricata-watch.sh' "$wf"
	grep -qE 'uses: actions/checkout@[0-9a-f]{40}' "$wf"
	grep -q 'contents: read' "$wf"
	grep -q 'issues: write' "$wf"
	run grep -c 'contents: write\|pull-requests: write' "$wf"
	[ "$output" = "0" ]
}
