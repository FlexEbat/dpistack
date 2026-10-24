#!/usr/bin/env bash
# The automatic check of Suricata releases (run weekly by
# .github/workflows/suricata-watch.yml):
#  1. the pinned SURICATA_STABLE_REF must still build (drift of Rust,
#     nDPI or the runner image shows up here first);
#  2. a newer stable release of the same series is built, and the result
#     goes to an issue: "tested, raise the pin" or "does not build";
#  3. a newer series (for example 9.0) is announced once.
# It never changes the repository; raising the pin is a normal change that
# goes through the gate. Issues are not duplicated: one open issue per title.
# Exit status 1 only when the pinned release itself fails.
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="${SURICATA_RELEASE_CHECK:-$repo_dir/scripts/check-suricata-release.sh}"
build="${SURICATA_BUILD_CHECK:-$repo_dir/scripts/suricata-build-check.sh}"
gh_cmd="${GH:-gh}"

declare -A rel=()
info="$(bash "$check")" || true
while IFS='=' read -r key value; do
	[[ -n "$key" ]] && rel[$key]="$value"
done <<<"$info"

status="${rel[status]:-unknown}"
current="${rel[current]:-}"
latest="${rel[latest]:-}"
newer_series="${rel[newer_series]:-}"

if [[ "$status" == "unknown" ]]; then
	echo "suricata-watch: the release check gave no answer" >&2
	exit 1
fi

run_url=""
if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
	run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}"
fi

# issue <title> <body> - one open issue per title.
issue() {
	local title="$1" body="$2" open
	open="$("$gh_cmd" issue list --state open --search "\"$title\" in:title" --json title \
		--jq "[.[] | select(.title == \"$title\")] | length" 2>/dev/null)" || open=0
	if [[ "${open:-0}" == "0" ]]; then
		"$gh_cmd" issue create --title "$title" --body "$body${run_url:+

Run: $run_url}"
	else
		echo "suricata-watch: issue \"$title\" is already open"
	fi
}

result=0

echo "== pinned release: $current"
if ! bash "$build" "$current"; then
	issue "Suricata $current (SURICATA_STABLE_REF) no longer builds" \
		"The pinned release failed the build check with nDPI and the plugin. Possible causes: Rust or the runner image changed, nDPI, dependencies. Sort it out before the next release."
	result=1
fi

if [[ "$status" == "update" && -n "$latest" ]]; then
	echo "== newer release of the same series: $latest"
	if bash "$build" "$latest"; then
		issue "Suricata $latest verified: raise SURICATA_STABLE_REF" \
			"The new release $latest builds with nDPI and the plugin and loads the installer's configuration. To accept it: change SURICATA_STABLE_REF in lib/step_suricata.sh to $latest, update the version in tech.md and go the usual way: dev, gate, PR to main."
	else
		issue "Suricata $latest failed the build check" \
			"The new release $latest did not build with nDPI and the plugin or did not load the configuration. SURICATA_STABLE_REF stays $current. Find out what changed (minimum Rust, the nDPI plugin API) and fix the installer."
	fi
fi

if [[ -n "$newer_series" ]]; then
	issue "A new Suricata series is out: $newer_series" \
		"The stable series $newer_series is newer than the pinned one ($current). Moving to a new series is a separate decision: it needs a check of the nDPI plugin, the OISF COPR and the PPA of that series. SURICATA_COPR in lib/os.sh is tied to the series."
fi

exit "$result"
