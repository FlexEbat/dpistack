#!/usr/bin/env bash
# `dpistack pcap analyze FILE`: replays a capture the owner brings through
# Suricata offline with the live rules, the live exceptions and the real
# HOME_NET, and says which alerts and which application protocols it
# produced (task 60). Nothing is written to the live logs: the run has a
# private directory that is deleted afterwards. Sourced by install.sh; it
# defines functions only.

PCAP_TIMEOUT_SEC=600
PCAP_TEMPLATE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../templates" &>/dev/null && pwd)"

# pcap_magic_ok <file> - classic pcap (both byte orders, micro and nano
# seconds) or pcapng. Anything else is not a capture, whatever its name.
pcap_magic_ok() {
	local magic
	magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
	case "$magic" in
	d4c3b2a1 | a1b2c3d4 | 4d3cb2a1 | a1b23c4d | 0a0d0d0a) return 0 ;;
	esac
	return 1
}

# pcap_emit <json:0|1> <doc>
pcap_emit() {
	if (($1)); then
		jq -c . <<<"$2"
		return 0
	fi
	jq -r '
		if .ran | not then "not analyzed: " + .reason
		else
			"analyzed \(.file) (\(.bytes) bytes): \(.flows) flows, \(.packets) packets, \(.alerts | length) different alerts",
			(if (.alerts | length) > 0 then "alerts:" else empty end),
			(.alerts[] | "  sid \(.sid)  x\(.count)  severity \(.severity)  \(.msg)  (\(.src) -> \(.dest))" + (if .would_drop then "  [would drop]" else "" end)),
			(if (.protocols | length) > 0 then "application protocols:" else "no application protocol was recognized" end),
			(.protocols[] | "  \(.app_proto)  \(.flows) flows, \(.bytes) bytes")
		end' <<<"$2"
}

# pcap_analyze <file> [--json]
pcap_analyze() {
	local file="" json=0
	while (($#)); do
		case "$1" in
		--json)
			json=1
			shift
			;;
		-*) fail 2 "pcap analyze: unknown option: $1" ;;
		*)
			[[ -z "$file" ]] || fail 2 "pcap analyze: one file at a time"
			file="$1"
			shift
			;;
		esac
	done
	[[ -n "$file" ]] || fail 2 "pcap analyze: a capture file is needed"
	[[ -f "$file" && -r "$file" ]] || fail 5 "pcap analyze: no such file: $file"
	local bytes max_mb
	bytes=$(stat -c %s "$file")
	max_mb=$(conf_get PCAP_MAX_MB 100)
	((bytes > 0)) || fail 5 "pcap analyze: the file is empty"
	((bytes <= max_mb * 1048576)) || fail 5 "pcap analyze: the file is $((bytes / 1048576)) MiB, the limit is $max_mb MiB (PCAP_MAX_MB)"
	pcap_magic_ok "$file" || fail 5 "pcap analyze: not a pcap or pcapng file"

	local reason=""
	if [[ "$(conf_get SURICATA_RUNTIME native)" == docker ]]; then
		reason="Suricata runs in a container: the offline analysis needs a Suricata on the host"
	elif ! command -v suricata >/dev/null 2>&1; then
		reason="suricata is not installed"
	elif [[ ! -f "$(path_suricata_ruleset)" ]]; then
		reason="there is no rule set yet: run dpistack rules-update"
	fi
	local name
	name=$(basename "$file")
	if [[ -n "$reason" ]]; then
		pcap_emit "$json" "$(jq -nc --arg r "$reason" --arg f "$name" '{ran:false, file:$f, reason:$r}')"
		return 0
	fi

	local tmp rc=0 out plugins="" threshold="" home
	tmp=$(mktemp -d)
	chmod 0700 "$tmp"
	[[ -e "$(path_suricata_ndpi_plugin)" ]] && plugins=$'plugins:\n'"  - $(path_suricata_ndpi_plugin)"
	[[ -f "$(path_suricata_threshold)" ]] && threshold="threshold-file: $(path_suricata_threshold)"
	home=$(conf_get HOME_NET auto)
	[[ -z "$home" || "$home" == auto ]] && home='[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]'
	render_template "$PCAP_TEMPLATE_DIR/suricata-analyze.yaml.tpl" \
		"HOME_NET=$home" "RULE_DIR=$(dirname "$(path_suricata_ruleset)")" "RULE_FILE=$(path_suricata_ruleset)" \
		"THRESHOLD=$threshold" "PLUGINS=$plugins" >"$tmp/analyze.yaml" || {
		rm -rf "$tmp"
		fail 1 "pcap analyze: could not prepare the offline configuration"
	}
	out=$(timeout "$PCAP_TIMEOUT_SEC" suricata -r "$file" -c "$tmp/analyze.yaml" -l "$tmp" -k none 2>&1) || rc=$?

	local alerts='[]' protocols='[]' totals='{"flows":0,"packets":0}'
	if [[ -f "$tmp/eve.json" ]]; then
		alerts=$(jq -c 'select(.event_type == "alert") | {sid: .alert.signature_id, msg: .alert.signature, severity: (.alert.severity // 3), would_drop: (.alert.action == "blocked"), src: ((.src_ip // "?") + ":" + ((.src_port // 0) | tostring)), dest: ((.dest_ip // "?") + ":" + ((.dest_port // 0) | tostring))}' "$tmp/eve.json" 2>/dev/null |
			jq -sc 'group_by(.sid) | map(.[0] + {count: length}) | sort_by(-.count, .sid)') || alerts='[]'
		protocols=$(jq -c 'select(.event_type == "flow") | {app_proto: (.app_proto // "unknown"), bytes: (((.flow.bytes_toserver // 0) + (.flow.bytes_toclient // 0)))}' "$tmp/eve.json" 2>/dev/null |
			jq -sc 'group_by(.app_proto) | map({app_proto: .[0].app_proto, flows: length, bytes: (map(.bytes) | add)}) | sort_by(-.flows, .app_proto)') || protocols='[]'
		totals=$(jq -c 'select(.event_type == "flow") | {p: ((.flow.pkts_toserver // 0) + (.flow.pkts_toclient // 0))}' "$tmp/eve.json" 2>/dev/null |
			jq -sc '{flows: length, packets: (map(.p) | add // 0)}') || totals='{"flows":0,"packets":0}'
	fi
	rm -rf "$tmp"
	local doc
	doc=$(jq -nc --arg f "$name" --argjson bytes "$bytes" --argjson rc "$rc" --argjson a "$alerts" --argjson p "$protocols" --argjson t "$totals" \
		--arg tail "$( ((rc != 0)) && printf '%s' "$out" | tail -n 1)" \
		'{ran: ($rc == 0), file: $f, bytes: $bytes, flows: $t.flows, packets: $t.packets, alerts: $a, protocols: $p}
		 + (if $rc != 0 then {reason: ("suricata -r exited with code \($rc): " + $tail)} else {} end)')
	pcap_emit "$json" "$doc"
	return 0
}

# cmd_pcap analyze <file> [--json]
cmd_pcap() {
	local sub="${1:-}"
	[[ $# -eq 0 ]] || shift
	case "$sub" in
	analyze) pcap_analyze "$@" ;;
	*) fail 2 "pcap: analyze <file> [--json]" ;;
	esac
}
