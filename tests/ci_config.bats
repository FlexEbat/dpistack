#!/usr/bin/env bats
# Guards the CI/CD files and the version bookkeeping that a release
# depends on.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WF="$REPO_DIR/.github/workflows"
}

@test "every workflow is valid YAML and sets explicit permissions" {
	for f in "$WF"/*.yml; do
		python3 -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert 'jobs' in d" "$f"
		grep -q '^permissions:' "$f"
	done
}

@test "no workflow uses pull_request_target or untrusted event text in run steps" {
	! grep -q 'pull_request_target' "$WF"/*.yml
	! grep -nE 'run:.*\$\{\{ *github\.(head_ref|event\.(issue|pull_request|comment))' "$WF"/*.yml
}

@test "every third-party action is pinned to a version, not a branch" {
	run grep -hoE 'uses: [^ ]+' "$WF"/*.yml
	[ "$status" -eq 0 ]
	while read -r _ action; do
		[[ "$action" == *@* ]]
		[[ "${action##*@}" != "main" && "${action##*@}" != "master" ]]
	done <<<"$output"
}

@test "the CI gate and the release gate run the same script" {
	grep -q 'bash scripts/gate.sh' "$WF/ci.yml"
	grep -q 'bash scripts/gate.sh' "$WF/release.yml"
}

@test "the release tag check compares with the version in lib/common.sh" {
	grep -q 'DPISTACK_VERSION' "$WF/release.yml"
	grep -qE '^DPISTACK_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$REPO_DIR/lib/common.sh"
}

@test "the program version in tech.md is the one in the code" {
	code="$(sed -n 's/^DPISTACK_VERSION="\(.*\)"$/\1/p' "$REPO_DIR/lib/common.sh")"
	doc="$(sed -n 's/.*Версия программы: v\([0-9.]*\)\*\*.*/\1/p' "$REPO_DIR/tech.md" | head -1)"
	[ -n "$code" ]
	[ "$code" = "$doc" ]
}

@test "every action is pinned to a full commit SHA, not a movable tag" {
	run grep -hoE 'uses: [^ ]+' "$WF"/*.yml
	[ "$status" -eq 0 ]
	while read -r _ action; do
		[[ "${action##*@}" =~ ^[0-9a-f]{40}$ ]] || {
			echo "not pinned by SHA: $action"
			return 1
		}
	done <<<"$output"
}

@test "no workflow pipes a download into a shell" {
	! grep -nE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' "$WF"/*.yml
	! grep -nE 'bash <\((curl|wget)' "$WF"/*.yml
}

@test "a release tag must be on main" {
	grep -q 'merge-base --is-ancestor' "$WF/release.yml"
}

@test "files the release archive copies exist" {
	for f in README.md LICENSE dpistack.conf.example install.sh lib templates bin tests/data; do
		[ -e "$REPO_DIR/$f" ]
	done
}

@test "the gate runs as root in every workflow: the installer refuses to run otherwise" {
	run grep -n 'scripts/gate.sh' "$WF"/ci.yml "$WF"/release.yml
	[ "$status" -eq 0 ]
	while IFS= read -r line; do
		[[ "$line" == *"sudo -E env"* ]] || {
			echo "gate not run through sudo: $line"
			return 1
		}
	done <<<"$output"
}
