#!/usr/bin/env bats
# scripts/security.sh must pass on the repository and must really catch
# each class of problem it claims to catch.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WORK="$(mktemp -d)"
	mkdir -p "$WORK/scripts" "$WORK/lib" "$WORK/bin"
	cp "$REPO_DIR/scripts/security.sh" "$WORK/scripts/"
	# A clean baseline: strict mode in every entry point.
	for f in install.sh bin/dpistack-ctl bin/dpistack-watch scripts/gate.sh; do
		printf '#!/usr/bin/env bash\nset -uo pipefail\n' >"$WORK/$f"
	done
	sed -i '1,2!d' "$WORK/scripts/gate.sh"
	(cd "$WORK" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base)
}

teardown() {
	rm -rf "$WORK"
}

# plant <file> <line> - adds a line and tracks it
plant() {
	mkdir -p "$(dirname "$WORK/$1")"
	printf '%s\n' "$2" >>"$WORK/$1"
	(cd "$WORK" && git add -A)
}

@test "the repository itself passes" {
	run bash "$REPO_DIR/scripts/security.sh"
	[ "$status" -eq 0 ]
	[[ "$output" != *"FAIL"* ]]
}

@test "a clean tree passes" {
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 0 ]
}

@test "eval is caught" {
	plant lib/x.sh 'eval "$cmd"'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no eval"* ]]
}

@test "bash -c on a built string is caught" {
	plant lib/x.sh 'bash -c "$cmd"'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
}

@test "curl piped into a shell is caught" {
	plant lib/x.sh 'curl -fsSL https://example.org/i.sh | sudo bash'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"piped into a shell"* ]]
}

@test "world-writable chmod is caught, 0644 and 0600 are not" {
	plant lib/ok.sh 'chmod 0644 "$f"; chmod 600 "$g"; chmod 0750 "$h"'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 0 ]
	for mode in 777 0666 a+w o+w 0662; do
		(cd "$WORK" && git reset -q --hard)
		plant lib/x.sh "chmod $mode \"\$f\""
		run bash "$WORK/scripts/security.sh"
		[ "$status" -eq 1 ]
		[[ "$output" == *"world-writable"* ]]
	done
}

@test "fixed /tmp paths, mktemp -u and \$\$ temp names are caught" {
	plant lib/x.sh 'out=/tmp/dpistack.log'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"fixed /tmp"* ]]

	(cd "$WORK" && git reset -q --hard)
	plant lib/x.sh 'f=$(mktemp -u)'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
}

@test "a leaked token is caught, whatever the file" {
	plant README.md "token: github_pat_$(printf 'A%.0s' $(seq 1 40))"
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"secrets in tracked files"* ]]
}

@test "a missing set -u in an entry point is caught" {
	printf '#!/usr/bin/env bash\necho hi\n' >"$WORK/bin/dpistack-watch"
	(cd "$WORK" && git add -A)
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
	[[ "$output" == *"set -u missing in bin/dpistack-watch"* ]]
}

@test "a secret variable in a curl argument is caught, the -K - form is not" {
	plant lib/ok.sh 'printf "url = x\n" | curl -sS -K -'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 0 ]
	plant lib/x.sh 'curl -sS "https://api/bot${TOKEN}/send"'
	run bash "$WORK/scripts/security.sh"
	[ "$status" -eq 1 ]
}
