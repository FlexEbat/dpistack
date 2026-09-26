#!/usr/bin/env bash
# The gate every slice must pass before it is done (tech.md section 12).
set -uo pipefail

status=0

echo "== shfmt =="
if ! shfmt -d install.sh lib bin scripts tests; then
	status=1
fi

echo "== shellcheck =="
# shellcheck disable=SC2046
if ! shellcheck -x install.sh lib/*.sh bin/dpistack-ctl bin/dpistack-watch scripts/*.sh; then
	status=1
fi

echo "== bats =="
if ! bats tests; then
	status=1
fi

if [[ -d panel ]]; then
	echo "== gofmt =="
	if [[ -n "$(gofmt -l panel)" ]]; then
		gofmt -l panel
		status=1
	fi

	echo "== go vet =="
	(cd panel && go vet ./...) || status=1

	echo "== go test =="
	(cd panel && go test ./...) || status=1
fi

exit "$status"
