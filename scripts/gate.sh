#!/usr/bin/env bash
# The gate every slice must pass before it is done (tech.md section 12).
set -uo pipefail

status=0

# fail <stage> marks the gate red and names the stage, so a red run says
# which check broke even when that check prints nothing recognisable.
fail() {
	echo "FAIL: $1"
	status=1
}

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
if ! LANG=C.utf8 LC_ALL=C.utf8 shellcheck -x install.sh lib/*.sh bin/dpistack-ctl bin/dpistack-watch scripts/*.sh; then
	fail shellcheck
fi

echo "== security =="
if ! bash scripts/security.sh; then
	fail security
fi

echo "== conf example =="
if ! bash scripts/check-conf-example.sh; then
	fail "conf example"
fi

echo "== bats =="
if ! bats tests; then
	fail bats
fi

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

	echo "== panel budget =="
	bash scripts/panel-budget.sh || fail "panel budget"
fi

exit "$status"
