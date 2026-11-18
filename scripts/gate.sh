#!/usr/bin/env bash
# The gate every task must pass before it is done (tech.md section 12).
set -uo pipefail

# gate.sh                      every check, as before (local work, the release)
# gate.sh --no-bats            every check except the bats suite
# gate.sh --bats-shard I/N     only shard I of N of the bats suite (scripts/bats-shard.sh)
# CI runs the shards and the rest as separate jobs (tech.md 18.58, task 50).
mode=all
shard=""
case "${1:-}" in
"") ;;
--no-bats) mode=nobats ;;
--bats-shard)
	mode=shard
	shard="${2:-}"
	[[ "$shard" =~ ^[0-9]+/[0-9]+$ ]] || {
		echo "gate: --bats-shard I/N" >&2
		exit 2
	}
	;;
*)
	echo "usage: gate.sh [--no-bats | --bats-shard I/N]" >&2
	exit 2
	;;
esac

status=0

# fail <stage> marks the gate red and names the stage, so a red run says
# which check broke even when that check prints nothing recognisable.
fail() {
	echo "FAIL: $1"
	status=1
}

if [[ "$mode" != "shard" ]]; then
	echo "== shfmt =="
	if ! shfmt -d install.sh lib bin scripts tests; then
		fail shfmt
	fi

	echo "== shellcheck =="
	# LANG/LC_ALL=C.utf8: under the POSIX locale, shellcheck's Haskell
	# runtime unreliably crashes (commitBuffer/openBinaryFile: invalid
	# argument) on scripts with enough Cyrillic text - a real environment
	# bug, not a script problem; lib/menu.sh is the first file dense
	# enough in Russian strings to hit it consistently.
	# shellcheck disable=SC2046
	if ! LANG=C.utf8 LC_ALL=C.utf8 shellcheck -x install.sh lib/*.sh bin/dpistack-watch scripts/*.sh dpistack-install.sh; then
		fail shellcheck
	fi

	echo "== security =="
	if ! bash scripts/security.sh; then
		fail security
	fi

	echo "== bundle =="
	# dpistack-install.sh is generated: a source changed without rebuilding it
	# fails here, not on a user's machine.
	if ! bash scripts/bundle.sh --check; then
		fail bundle
	fi

	echo "== conf example =="
	if ! bash scripts/check-conf-example.sh; then
		fail "conf example"
	fi

	echo "== config reference =="
	if ! bash scripts/gen-config-doc.sh --check; then
		fail "config reference"
	fi

	echo "== key hints =="
	if ! bash scripts/gen-key-hints.sh --check; then
		fail "key hints"
	fi
fi

echo "== bats ($mode) =="
if [[ "$mode" == "shard" ]]; then
	mapfile -t files < <(bash scripts/bats-shard.sh "${shard%/*}" "${shard#*/}")
	echo "shard $shard: ${#files[@]} files"
	if ! bats "${files[@]}"; then
		fail "bats shard $shard"
	fi
elif [[ "$mode" == "all" ]]; then
	if ! bats tests; then
		fail bats
	fi
fi

if [[ "$mode" != "shard" ]]; then
	if [[ -d panel ]]; then
		echo "== gofmt =="
		if [[ -n "$(gofmt -l panel)" ]]; then
			gofmt -l panel
			fail gofmt
		fi

		echo "== go vet =="
		(cd panel && go vet ./...) || fail "go vet"

		echo "== go test =="
		(cd panel && go test ./...) || fail "go test"

		echo "== panel js =="
		if command -v node >/dev/null 2>&1; then
			(cd panel/web && node --test test/*.test.mjs) || fail "panel js"
		else
			echo "node not found, skipped"
		fi
	fi
fi

exit "$status"
