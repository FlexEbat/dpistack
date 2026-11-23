#!/usr/bin/env bash
# The reading side of the history that the watchdog keeps (task 61): the
# day files in history/YYYY-MM-DD.json, `dpistack report daily|weekly` and
# `dpistack devices`. The watchdog and the verbs share the jq text that adds
# two roll-ups. Sourced by install.sh and by bin/dpistack-watch; it defines
# functions only.

# jq program text: the sum of two objects of counters, level by level.
# shellcheck disable=SC2016 # jq variables, not shell ones
HISTORY_JQ_MERGE='def msum(a; b): reduce (b | to_entries[]) as $e (a;
	.[$e.key] = (if ((.[$e.key] | type) == "object") and ($e.value | type) == "object" then msum(.[$e.key]; $e.value)
		elif ((.[$e.key] | type) == "number") and ($e.value | type) == "number" then .[$e.key] + $e.value
		else $e.value end));'

HISTORY_TOP=10

history_today() { date -u -d "@$(now_epoch)" +%Y-%m-%d; }
now_epoch() { echo "${DPISTACK_NOW:-$(date +%s)}"; }

# history_collect <from> <to> - the days of the range that have a file,
# added up, as one JSON object with the list of those days.
history_collect() {
	local from="$1" to="$2" dir f day
	dir=$(path_history_dir)
	local -a files=()
	for f in "$dir"/*.json; do
		[[ -e "$f" ]] || continue
		day=$(basename "$f" .json)
		[[ ! "$day" < "$from" && ! "$day" > "$to" ]] && files+=("$f")
	done
	if ((${#files[@]} == 0)); then
		echo '{"days":[]}'
		return 0
	fi
	jq -sc "$HISTORY_JQ_MERGE"' {days: map(.date)} + (reduce .[] as $d ({}; msum(.; ($d | del(.date)))))' "${files[@]}"
}

# history_report <from> <to> <label> <json:0|1>
history_report() {
	local from="$1" to="$2" label="$3" json="$4" sum devices
	sum=$(history_collect "$from" "$to")
	devices=$(path_devices_json)
	local known="{}"
	[[ -r "$devices" ]] && known=$(jq -c . "$devices" 2>/dev/null || echo "{}")
	local doc
	doc=$(jq -nc --argjson s "$sum" --argjson k "$known" --arg from "$from" --arg to "$to" --arg label "$label" --argjson top "$HISTORY_TOP" '
		{label: $label, from: $from, to: $to, days: ($s.days // []), flows: ($s.flows // 0), bytes: ($s.bytes // 0),
		 apps: (($s.apps // {}) | to_entries | map({app: .key, flows: .value.flows, bytes: .value.bytes}) | sort_by(-.bytes, .app) | .[0:$top]),
		 devices: (($s.devices // {}) | to_entries | map({ip: .key, flows: .value.flows, bytes: .value.bytes,
			top_app: ((.value.apps // {}) | to_entries | sort_by(-.value, .key) | (.[0].key // ""))}) | sort_by(-.bytes, .ip) | .[0:$top]),
		 alerts: (($s.alerts // {}) | to_entries | map({sid: (.key | tonumber), count: .value.count, msg: .value.msg, severity: .value.severity}) | sort_by(-.count, .sid) | .[0:$top]),
		 new_devices: ($k | to_entries | map(select(.value.first >= $from and .value.first <= $to)) | map(.key) | sort)}')
	if ((json)); then
		jq -c . <<<"$doc"
		return 0
	fi
	jq -r '
		def size: if . < 1024 then "\(.) B" elif . < 1048576 then "\((. / 1024 * 10 | floor) / 10) KiB" elif . < 1073741824 then "\((. / 1048576 * 10 | floor) / 10) MiB" else "\((. / 1073741824 * 10 | floor) / 10) GiB" end;
		"\(.label) report \(.from) to \(.to)",
		(if (.days | length) == 0 then "no history for these days: is HISTORY_ENABLE=yes and has the watchdog run since?"
		else
			"days with data: \(.days | length) (\(.days | join(", ")))",
			"flows: \(.flows), traffic: \(.bytes | size)",
			"",
			"applications (by traffic):",
			(.apps[] | "  \(.app)  \(.flows) flows  \(.bytes | size)"),
			"",
			"devices (by traffic):",
			(.devices[] | "  \(.ip)  \(.flows) flows  \(.bytes | size)" + (if .top_app != "" then "  mostly \(.top_app)" else "" end)),
			"",
			(if (.alerts | length) == 0 then "alerts: none" else "alerts (by count):" end),
			(.alerts[] | "  sid \(.sid)  x\(.count)  severity \(.severity)  \(.msg)"),
			"",
			(if (.new_devices | length) == 0 then "new devices: none" else "new devices: \(.new_devices | join(", "))" end)
		end)' <<<"$doc"
}

# cmd_report daily|weekly [--date YYYY-MM-DD] [--json]
cmd_report() {
	local kind="${1:-}" date="" json=0
	[[ $# -eq 0 ]] || shift
	case "$kind" in daily | weekly) ;; *) fail 2 "report: daily|weekly [--date YYYY-MM-DD] [--json]" ;; esac
	while (($#)); do
		case "$1" in
		--json)
			json=1
			shift
			;;
		--date)
			(($# >= 2)) || fail 2 "report: --date needs a day"
			date="$2"
			shift 2
			;;
		*) fail 2 "report: unknown option: $1" ;;
		esac
	done
	[[ -n "$date" ]] || date=$(history_today)
	if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -u -d "$date" +%Y-%m-%d >/dev/null 2>&1; then
		fail 5 "report: --date is a day like 2026-11-20"
	fi
	if [[ "$kind" == daily ]]; then
		history_report "$date" "$date" daily "$json"
	else
		history_report "$(date -u -d "$date - 6 days" +%Y-%m-%d)" "$date" weekly "$json"
	fi
}

# cmd_devices [--json] - the private addresses seen, newest first.
cmd_devices() {
	local json=0 file
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "devices: [--json]" ;;
	esac
	file=$(path_devices_json)
	local doc="[]"
	[[ -r "$file" ]] && doc=$(jq -c 'to_entries | map({ip: .key, first: .value.first, last: .value.last}) | sort_by(.last, .ip) | reverse' "$file" 2>/dev/null || echo "[]")
	if ((json)); then
		echo "$doc"
	elif [[ "$doc" == "[]" ]]; then
		echo "no device recorded yet: it needs HISTORY_ENABLE=yes and a watchdog run with traffic"
	else
		jq -r '.[] | "\(.ip)  first seen \(.first)  last seen \(.last)"' <<<"$doc"
	fi
}
