#!/usr/bin/env bash
# dev-tools.sh [--check | --install] - the lint tools of the CI, in the same
# versions, for local work (tech.md 18.58, slice 56).
#
# The CI installs shellcheck and shfmt from Ubuntu 24.04. A newer build on a
# developer machine passes what the CI refuses (the style finding SC2015 of
# v0.50.0) or refuses what the CI passes (the spacing of `((! x))`), so the
# gate looks green or red for the wrong reason. --check says which versions
# are on the PATH; --install installs the CI ones from apt (Debian, Ubuntu).
set -uo pipefail

WANT_SHELLCHECK="0.9.0"
WANT_SHFMT="3.8.0"

# tool_version <name> - the version number of a tool on the PATH, without a
# leading v, or nothing when the tool is not there.
tool_version() {
	local out
	command -v "$1" >/dev/null 2>&1 || return 0
	case "$1" in
	shellcheck) out=$("$1" --version 2>/dev/null | sed -n 's/^version: *//p') ;;
	*) out=$("$1" --version 2>/dev/null | head -n1) ;;
	esac
	echo "${out#v}"
}

check() {
	local name want have rc=0
	for name in shellcheck shfmt; do
		if [[ "$name" == shellcheck ]]; then want="$WANT_SHELLCHECK"; else want="$WANT_SHFMT"; fi
		have=$(tool_version "$name")
		if [[ -z "$have" ]]; then
			echo "missing: $name (the CI uses $want)"
			rc=1
		elif [[ "$have" != "$want" ]]; then
			echo "different: $name is $have, the CI uses $want (see: $(command -v "$name"))"
			rc=1
		else
			echo "ok: $name $have"
		fi
	done
	((rc == 0)) || echo "to install the CI versions on Debian or Ubuntu: sudo bash scripts/dev-tools.sh --install"
	return "$rc"
}

install_tools() {
	if ! command -v apt-get >/dev/null 2>&1; then
		echo "no apt-get here: install shellcheck $WANT_SHELLCHECK and shfmt $WANT_SHFMT by hand" >&2
		return 1
	fi
	[[ $EUID -eq 0 ]] || {
		echo "run it as root: sudo bash scripts/dev-tools.sh --install" >&2
		return 1
	}
	DEBIAN_FRONTEND=noninteractive apt-get install -y shellcheck shfmt || return 1
	echo "installed; the first shellcheck and shfmt on the PATH must be the ones from /usr/bin:"
	check
}

case "${1:---check}" in
--check) check ;;
--install) install_tools ;;
*)
	echo "usage: dev-tools.sh [--check | --install]" >&2
	exit 2
	;;
esac
