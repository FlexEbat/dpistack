#!/usr/bin/env bash
# The Alert Center (tech.md 18.43): the alerts of the watchdog and of
# Suricata, with a state a person sets: new, acknowledged, snoozed until,
# resolved. Nothing is stored about the alerts themselves: they are read each
# time, a watchdog alert from health.json (a check that is warn or crit) and a
# Suricata alert from the tail of eve.json (one per rule, with a count). What
# is stored, in /var/lib/dpistack/alerts-state.json, is what people decided:
#
#   {"version":1,"alerts":{"watch:disk.free":{"state":"acknowledged","at":"...",
#    "by":"admin","note":"...","until":null,"title":"...",...}},"history":[...]}
#
# The file has one writer, `dpistack alerts` as root (the panel calls the
# verb), under a lock and replaced atomically. Sourced by install.sh; it
# defines functions only.

ALERTS_KEY_RE='^(watch:[a-z0-9_.-]{1,64}|sid:[0-9]{1,10})$'
ALERTS_NOTE_RE='^[A-Za-z0-9 ._:/@+,=-]{0,80}$'
ALERTS_BY_RE='^[A-Za-z0-9][A-Za-z0-9._@-]{0,31}$'
ALERTS_EVE_TAIL=8388608
ALERTS_KEEP_DAYS=30
ALERTS_HISTORY_MAX=500
ALERTS_HISTORY_SHOW=100

alerts_now() { "${DPISTACK_NOW_CMD:-date}" +%s; }

# alerts_iso <epoch> - UTC, in the form of health.json and events.jsonl.
alerts_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# alerts_eve_lines - the alert events of the tail of eve.json, one JSON object
# a line. A line cut by the tail, or one that is not JSON, is skipped.
alerts_eve_lines() {
	local eve
	eve=$(path_suricata_eve_json)
	[[ -r "$eve" ]] || return 0
	tail -c "$ALERTS_EVE_TAIL" "$eve" 2>/dev/null | grep -F '"event_type":"alert"' |
		jq -cR 'fromjson? | select(.event_type == "alert")' 2>/dev/null || true
}

# alerts_conditions - what is wrong now, as a JSON array. `activity` is the
# time of the last change, to tell a resolved alert that came back.
alerts_conditions() {
	local health watch='[]' suri='[]'
	health=$(path_health_json)
	if [[ -r "$health" ]]; then
		watch=$(jq -c '. as $h | [.checks[]? | select(.status == "warn" or .status == "crit")
			| {key: ("watch:" + .id), source: "watchdog", severity: .status, title: .id,
			   detail: ((.value | tostring) + (if (.detail // "") != "" then ": " + .detail else "" end)),
			   first_seen: (.since // $h.ts), last_seen: $h.ts, count: null, activity: (.since // $h.ts)}]' "$health" 2>/dev/null) || watch='[]'
	fi
	suri=$(alerts_eve_lines | jq -sc 'group_by(.alert.signature_id)
		| map({key: ("sid:" + (.[0].alert.signature_id | tostring)), source: "suricata",
		       severity: (if (.[0].alert.severity // 3) <= 1 then "crit" elif .[0].alert.severity == 2 then "warn" else "info" end),
		       title: .[0].alert.signature, detail: (.[0].alert.category // ""),
		       first_seen: (map(.timestamp) | min), last_seen: (map(.timestamp) | max),
		       count: length, activity: (map(.timestamp) | max)})' 2>/dev/null) || suri='[]'
	jq -nc --argjson a "$watch" --argjson b "$suri" '$a + $b'
}

alerts_state_read() {
	local f
	f=$(path_alerts_state)
	if [[ -r "$f" ]] && jq -e 'type == "object" and (.alerts | type == "object")' "$f" >/dev/null 2>&1; then
		cat "$f"
	else
		echo '{"version":1,"alerts":{},"history":[]}'
	fi
}

# alerts_merge <conditions> <state> <now> - every alert with its effective
# state, the ones that cleared after a decision included (state resolved).
alerts_merge() {
	jq -nc --argjson conds "$1" --argjson st "$2" --argjson now "$3" '
		def rank: {new: 0, acknowledged: 1, snoozed: 2, resolved: 3}[.];
		def sev: {crit: 0, warn: 1, info: 2}[.];
		($st.alerts // {}) as $dec
		| ($conds | map(. as $c | ($dec[$c.key] // null) as $d
			| del(.activity) + {
				state: (if $d == null then "new"
					elif $d.state == "acknowledged" then "acknowledged"
					elif $d.state == "snoozed" then (if $d.until > $now then "snoozed" else "new" end)
					elif $d.state == "resolved" then (if ($c.activity[0:19]) > ($d.at[0:19]) then "new" else "resolved" end)
					else "new" end),
				by: ($d.by // null), note: ($d.note // ""), decided_at: ($d.at // null),
				until: (if $d != null and $d.state == "snoozed" and $d.until > $now then $d.until else null end),
				cleared: false}))
		+ ($dec | to_entries | map(select(.key as $k | ($conds | map(.key) | index($k)) == null)
			| .value + {key: .key, state: "resolved", decided_at: .value.at, until: null, cleared: true}
			| {key, source, severity, title, detail, first_seen, last_seen, count, state, by, note, decided_at, until, cleared}))
		| sort_by(.last_seen) | reverse | sort_by([(.state | rank), (.severity | sev)])'
}

alerts_counts() {
	jq -c '{new: (map(select(.state == "new")) | length),
		acknowledged: (map(select(.state == "acknowledged")) | length),
		snoozed: (map(select(.state == "snoozed")) | length),
		resolved: (map(select(.state == "resolved")) | length),
		new_crit: (map(select(.state == "new" and .severity == "crit")) | length)}' <<<"$1"
}

# alerts_list [--state S] [--source S] [--severity S] [--json]
alerts_list() {
	local json=0 fs="" fsrc="" fsev=""
	while (($#)); do
		case "$1" in
		--json)
			json=1
			shift
			;;
		--state | --source | --severity)
			[[ $# -ge 2 ]] || fail 2 "alerts list: $1 needs a value"
			case "$1" in
			--state)
				[[ "$2" =~ ^(new|acknowledged|snoozed|resolved)$ ]] || fail 5 "alerts list: state is new, acknowledged, snoozed or resolved"
				fs="$2"
				;;
			--source)
				[[ "$2" =~ ^(watchdog|suricata)$ ]] || fail 5 "alerts list: source is watchdog or suricata"
				fsrc="$2"
				;;
			--severity)
				[[ "$2" =~ ^(crit|warn|info)$ ]] || fail 5 "alerts list: severity is crit, warn or info"
				fsev="$2"
				;;
			esac
			shift 2
			;;
		*) fail 2 "alerts list: unknown argument: $1" ;;
		esac
	done
	command -v jq >/dev/null 2>&1 || fail 1 "alerts: jq is needed"
	local now all counts shown
	now=$(alerts_now)
	all=$(alerts_merge "$(alerts_conditions)" "$(alerts_state_read)" "$now")
	counts=$(alerts_counts "$all")
	shown=$(jq -c --arg s "$fs" --arg src "$fsrc" --arg sev "$fsev" \
		'map(select(($s == "" or .state == $s) and ($src == "" or .source == $src) and ($sev == "" or .severity == $sev)))' <<<"$all")
	local doc
	doc=$(jq -nc --arg ts "$(alerts_iso "$now")" --argjson a "$shown" --argjson c "$counts" '{ts: $ts, alerts: $a, counts: $c}')
	if ((json)); then
		printf '%s\n' "$doc"
		return 0
	fi
	jq -r '"alerts: \(.counts.new) new (\(.counts.new_crit) critical), \(.counts.acknowledged) acknowledged, \(.counts.snoozed) snoozed, \(.counts.resolved) resolved",
		(.alerts[] | "  [\(.state)] \(.severity) \(.key): \(.title)" + (if .count then " (x\(.count))" else "" end)
			+ (if .until then " until \(.until)" else "" end) + (if .by then " by \(.by)" else "" end))' <<<"$doc"
}

# alerts_history [--limit N] [--json] - what people did, and the status
# changes of the watchdog, the newest first.
alerts_history() {
	local json=0 limit="$ALERTS_HISTORY_SHOW"
	while (($#)); do
		case "$1" in
		--json)
			json=1
			shift
			;;
		--limit)
			[[ $# -ge 2 && "$2" =~ ^[0-9]{1,4}$ ]] || fail 5 "alerts history: --limit is a number"
			limit="$2"
			((limit >= 1 && limit <= ALERTS_HISTORY_MAX)) || fail 5 "alerts history: --limit is 1 to $ALERTS_HISTORY_MAX"
			shift 2
			;;
		*) fail 2 "alerts history: unknown argument: $1" ;;
		esac
	done
	command -v jq >/dev/null 2>&1 || fail 1 "alerts: jq is needed"
	local events='[]' ev
	ev=$(path_events_jsonl)
	if [[ -r "$ev" ]]; then
		events=$(tail -n 2000 "$ev" | jq -cR 'fromjson? | select(.ts and .check)
			| {ts, kind: "event", key: ("watch:" + .check), action: "status", by: null, note: "", detail: ((.from // "") + " to " + (.to // "") + (if (.detail // "") != "" then ": " + .detail else "" end))}' 2>/dev/null | jq -sc .) || events='[]'
	fi
	local doc
	doc=$(jq -nc --argjson st "$(alerts_state_read)" --argjson ev "$events" --argjson n "$limit" \
		'{history: ((($st.history // []) | map(. + {kind: "action", detail: (.title // "")})) + $ev | sort_by(.ts) | reverse | .[0:$n])}')
	if ((json)); then
		printf '%s\n' "$doc"
		return 0
	fi
	jq -r '.history[] | "\(.ts) \(.kind) \(.key) \(.action)" + (if .by then " by \(.by)" else "" end) + (if .detail != "" then " (\(.detail))" else "" end)' <<<"$doc"
}

# alerts_act ack|snooze|resolve|reopen <key> [--for 1h|4h|24h|7d] [--note T] [--by NAME]
alerts_act() {
	local action="$1" key="${2:-}" dur="" note="" by="${SUDO_USER:-root}"
	shift
	[[ $# -ge 1 ]] && shift
	[[ -n "$key" ]] || fail 2 "alerts $action: an alert key is needed (watch:<check> or sid:<number>)"
	while (($#)); do
		case "$1" in
		--for | --note | --by)
			[[ $# -ge 2 ]] || fail 2 "alerts $action: $1 needs a value"
			case "$1" in
			--for) dur="$2" ;;
			--note) note="$2" ;;
			--by) by="$2" ;;
			esac
			shift 2
			;;
		*) fail 2 "alerts $action: unknown argument: $1" ;;
		esac
	done
	[[ "$key" =~ $ALERTS_KEY_RE ]] || fail 5 "alerts $action: the key is watch:<check> or sid:<number>"
	[[ "$note" =~ $ALERTS_NOTE_RE ]] || fail 5 "alerts $action: the note is 80 characters of letters, digits and . _ : / @ + , = -"
	[[ "$by" =~ $ALERTS_BY_RE ]] || fail 5 "alerts $action: --by is a user name"
	local secs=0
	if [[ "$action" == snooze ]]; then
		case "$dur" in
		1h) secs=3600 ;;
		4h) secs=14400 ;;
		24h) secs=86400 ;;
		7d) secs=604800 ;;
		*) fail 5 "alerts snooze: --for is 1h, 4h, 24h or 7d" ;;
		esac
	elif [[ -n "$dur" ]]; then
		fail 5 "alerts $action: --for is only for snooze"
	fi
	command -v jq >/dev/null 2>&1 || fail 1 "alerts: jq is needed"
	command -v flock >/dev/null 2>&1 || fail 1 "alerts: flock is needed"

	local dir lock now at conds st snap
	dir=$(path_state_dir)
	mkdir -p "$dir" || fail 1 "alerts: cannot create $dir"
	lock="$dir/alerts-state.lock"
	exec {lock_fd}>"$lock" || fail 1 "alerts: cannot open the lock"
	flock -x "$lock_fd"
	now=$(alerts_now)
	at=$(alerts_iso "$now")
	conds=$(alerts_conditions)
	st=$(alerts_state_read)
	# What the alert looks like now, or as the decision remembers it.
	snap=$(jq -nc --arg k "$key" --argjson c "$conds" --argjson st "$st" '
		(($c | map(select(.key == $k)) | first) // null) as $live
		| if $live != null then $live | {source, severity, title, detail, first_seen, last_seen, count}
		  elif ($st.alerts[$k] // null) != null then $st.alerts[$k] | {source, severity, title, detail, first_seen, last_seen, count}
		  else null end')
	if [[ "$snap" == null ]]; then
		exec {lock_fd}>&-
		fail 5 "alerts $action: no such alert: $key"
	fi
	local cutoff new tmp
	cutoff=$(alerts_iso $((now - ALERTS_KEEP_DAYS * 86400)))
	new=$(jq -nc --arg k "$key" --arg action "$action" --arg at "$at" --arg by "$by" --arg note "$note" \
		--argjson secs "$secs" --argjson now "$now" --argjson snap "$snap" --argjson st "$st" --argjson conds "$conds" \
		--arg cutoff "$cutoff" --argjson max "$ALERTS_HISTORY_MAX" '
		def decision: {ack: "acknowledged", snooze: "snoozed", resolve: "resolved"}[$action];
		$st
		| if $action == "reopen" then del(.alerts[$k])
		  else .alerts[$k] = ($snap + {state: decision, at: $at, by: $by, note: $note,
				until: (if $action == "snooze" then $now + $secs else null end)}) end
		| .history = ((.history // []) + [{ts: $at, key: $k, action: $action, by: $by, note: $note, title: $snap.title}])[-$max:]
		| .alerts |= with_entries(select(.value.at[0:19] >= $cutoff[0:19]
			or (.value.state != "resolved" and (.key as $x | $conds | map(.key) | index($x)) != null)))
		| .version = 1')
	tmp=$(mktemp "$dir/alerts-state.XXXXXX") || fail 1 "alerts: cannot write in $dir"
	printf '%s\n' "$new" >"$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$(path_alerts_state)"
	exec {lock_fd}>&-
	case "$action" in
	ack) log INFO "alert $key acknowledged by $by" ;;
	snooze) log INFO "alert $key snoozed for $dur by $by" ;;
	resolve) log INFO "alert $key resolved by $by" ;;
	reopen) log INFO "alert $key reopened by $by" ;;
	esac
}

# cmd_alerts list|history|ack|snooze|resolve|reopen
cmd_alerts() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	list) alerts_list "$@" ;;
	history) alerts_history "$@" ;;
	ack | snooze | resolve | reopen) alerts_act "$sub" "$@" ;;
	*) fail 2 "alerts: list [--state S] [--source S] [--severity S] [--json] | history [--limit N] [--json] | ack|resolve|reopen <key> [--note T] | snooze <key> --for 1h|4h|24h|7d [--note T]" ;;
	esac
}
