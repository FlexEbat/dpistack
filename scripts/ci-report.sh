#!/usr/bin/env bash
# ci-report.sh <gate.log> <label> - what a failed CI job says about itself.
#
# CI used to name only the first failing line of a log in a commit status,
# without the reason under it, and the log itself sits on a host that tools
# outside GitHub cannot always reach. This reads the log the gate wrote and
# says the same thing in three places that are easy to read:
#   - workflow annotations (::error::), at most 10, shown on the run and read
#     through the check-runs API;
#   - the job summary ($GITHUB_STEP_SUMMARY): every failure with its reason;
#   - commit statuses (when GH_TOKEN and GITHUB_SHA are set), at most 6.
# A bats failure is "not ok N name" plus the lines that start with "#" under
# it; a gate stage failure is a "FAIL:" line, a Go "--- FAIL" or a panic. When
# the log holds none of these the last lines are reported, so a job that died
# for another reason (a download, a timeout) is never silent.
set -uo pipefail

log="${1:-}"
label="${2:-ci}"
[[ -r "$log" ]] || {
	echo "ci-report: no log to read: $log" >&2
	exit 2
}
max_annotations=10
max_statuses=6
max_detail=12
fence='```'

# esc <text> - the escaping of a workflow command.
esc() {
	local s="$1"
	s="${s//'%'/'%25'}"
	s="${s//$'\r'/'%0D'}"
	s="${s//$'\n'/'%0A'}"
	printf '%s' "$s"
}

# failures: one record per failure, fields split by the unit separator:
# title, then the detail lines joined with the record's own newline marker.
mapfile -t records < <(
	LC_ALL=C awk -v maxd="$max_detail" '
		function flush() { if (title != "") print title "\037" detail; title = ""; detail = ""; nd = 0 }
		/^not ok / { flush(); title = $0; next }
		/^ok / { flush(); next }
		title != "" && /^# / { if (nd < maxd) { detail = detail (nd ? "\036" : "") substr($0, 3); nd++ } next }
		/^(FAIL:|--- FAIL|FAIL[ \t]|panic:)/ { flush(); title = $0; next }
		/error:/ { flush(); title = $0; next }
		END { flush() }
	' "$log" | tr -d '\000'
)
if ((${#records[@]} == 0)); then
	tail_text=$(tail -n 8 "$log" | tr -d '\000' | tr '\n' '\036')
	records=("the job failed without a test or a check naming itself; last lines of the log"$'\x1f'"$tail_text")
fi

summary="${GITHUB_STEP_SUMMARY:-}"
[[ -n "$summary" ]] && printf '### %s: %d failure(s)\n\n' "$label" "${#records[@]}" >>"$summary"

n=0
for rec in "${records[@]}"; do
	n=$((n + 1))
	title="${rec%%$'\x1f'*}"
	detail="${rec#*$'\x1f'}"
	detail="${detail//$'\x1e'/$'\n'}"
	((n <= max_annotations)) && printf '::error title=%s::%s\n' "$(esc "$label #$n")" "$(esc "$title${detail:+$'\n'}$detail")"
	if [[ -n "$summary" ]]; then
		{
			printf '**%s**\n\n' "$title"
			[[ -n "$detail" ]] && printf '%s\n%s\n%s\n\n' "$fence" "$detail" "$fence"
		} >>"$summary"
	fi
	if ((n <= max_statuses)) && [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_SHA:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
		# the first detail line is the reason: it goes with the title
		reason="${detail%%$'\n'*}"
		text="$title${reason:+ | $reason}"
		gh api -X POST "repos/$GITHUB_REPOSITORY/statuses/$GITHUB_SHA" \
			-f state=failure -f context="$label #$n" -f description="${text:0:130}" >/dev/null || echo "ci-report: could not post the status $n" >&2
	fi
done
if ((${#records[@]} > max_annotations)); then
	printf '::warning title=%s::%s\n' "$(esc "$label")" "$(esc "${#records[@]} failures, the first $max_annotations are annotated; the job summary lists them all")"
fi
exit 0
