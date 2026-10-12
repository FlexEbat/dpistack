#!/usr/bin/env bash
# Compares SURICATA_STABLE_REF (lib/step_suricata.sh) with the tags of the
# Suricata repository and prints key=value lines:
#   current=<pinned tag>  latest=<newest stable tag of the same series>
#   newest=<newest stable tag of any series>  newer_series=<tag or empty>
#   status=up-to-date | update | ahead | unknown
# Only final releases count: release candidates, betas and dev tags do not
# match the pattern. SURICATA_TAGS_FILE replaces the network (tests).
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
current="$(sed -n 's/^SURICATA_STABLE_REF="\(suricata-[0-9][0-9.]*\)"$/\1/p' "$repo_dir/lib/step_suricata.sh" | head -n 1)"
if [[ -z "$current" ]]; then
	echo "status=unknown"
	echo "reason=SURICATA_STABLE_REF not found in lib/step_suricata.sh" >&2
	exit 2
fi

if [[ -n "${SURICATA_TAGS_FILE:-}" ]]; then
	tags="$(cat "$SURICATA_TAGS_FILE")"
else
	tags="$(git ls-remote --tags --refs "${SURICATA_REPO_URL:-https://github.com/OISF/suricata.git}" 'suricata-*' 2>/dev/null | sed 's#.*refs/tags/##')"
fi
if [[ -z "$tags" ]]; then
	echo "current=$current"
	echo "status=unknown"
	echo "reason=no tags received" >&2
	exit 2
fi

stable="$(grep -E '^suricata-[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tags" | sort -V)"
series="${current%.*}"
latest="$(grep -E "^${series//./\\.}\\.[0-9]+\$" <<<"$stable" | tail -n 1)"
newest="$(tail -n 1 <<<"$stable")"

status=unknown
if [[ -n "$latest" ]]; then
	if [[ "$latest" == "$current" ]]; then
		status=up-to-date
	elif [[ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)" == "$latest" ]]; then
		status=update
	else
		status=ahead
	fi
fi

newer_series=""
if [[ -n "$newest" && "${newest%.*}" != "$series" ]] &&
	[[ "$(printf '%s\n%s\n' "$current" "$newest" | sort -V | tail -n 1)" == "$newest" ]]; then
	newer_series="$newest"
fi

echo "current=$current"
echo "latest=$latest"
echo "newest=$newest"
echo "newer_series=$newer_series"
echo "status=$status"
