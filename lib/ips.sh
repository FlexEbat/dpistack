#!/usr/bin/env bash
# IPS mode (slice 29): the DPISTACK chain and its jumps. Shared by
# dpistack (mode, fw) and the installer (uninstall).
#
# The installer never flushes, deletes or reorders a chain that is not its
# own. What it does add to the standard chains is one rule each, the jump
# "-j DPISTACK" at position 1 (IPS_NFQ_CHAINS says which chains); the
# chain DPISTACK holds one NFQUEUE rule with --queue-bypass, so a stopped
# Suricata lets traffic through instead of cutting the network.

IPS_CHAIN="DPISTACK"
IPS_QUEUE_NUM=0
IPS_ALL_CHAINS=(INPUT OUTPUT FORWARD)

# ips_tools - the iptables front ends that exist (v4 and v6 if there).
ips_tools() {
	command -v iptables >/dev/null 2>&1 && echo iptables
	command -v ip6tables >/dev/null 2>&1 && echo ip6tables
	return 0
}

# ips_backend - which firewall front end carries the queue rules: iptables
# where it exists (also iptables-nft), nft on a system that has only nft
# (a minimal Rocky/Alma, say). Prints nothing when there is neither.
# nft keeps its own table "inet dpistack" (v4 and v6 in one), so the rules of
# the host stay untouched there too.
ips_backend() {
	if command -v iptables >/dev/null 2>&1; then
		echo iptables
	elif command -v nft >/dev/null 2>&1; then
		echo nft
	fi
	return 0
}

IPS_NFT_TABLE="dpistack"

# ips_nft_hook <chain> - the nft hook of an iptables chain name.
ips_nft_hook() {
	case "$1" in
	INPUT) echo input ;;
	OUTPUT) echo output ;;
	FORWARD) echo forward ;;
	esac
}

# ips_nft_ruleset <chains> - the table as one nft script. "add" and "delete"
# first make the rebuild atomic and repeatable whether or not it existed.
ips_nft_ruleset() {
	local chain hook
	echo "add table inet $IPS_NFT_TABLE"
	echo "delete table inet $IPS_NFT_TABLE"
	echo "table inet $IPS_NFT_TABLE {"
	for chain in $(ips_nfq_chains "$1"); do
		hook=$(ips_nft_hook "$chain")
		[[ -n "$hook" ]] || continue
		echo "	chain $hook {"
		echo "		type filter hook $hook priority -10; policy accept;"
		echo "		queue num $IPS_QUEUE_NUM bypass"
		echo "	}"
	done
	echo "}"
}

# ips_nfq_chains - the chains that get the jump, from IPS_NFQ_CHAINS.
ips_nfq_chains() {
	local list="${1:-INPUT,OUTPUT,FORWARD}" c
	local IFS=,
	for c in $list; do
		[[ -n "$c" ]] && echo "$c"
	done
	return 0
}

# ips_fw_apply <chains> - create and fill DPISTACK, put the jumps in.
# Repeatable: the chain is rebuilt, a jump is added only if missing.
ips_fw_apply() {
	local chains="$1" tool chain
	if [[ "$(ips_backend)" == "nft" ]]; then
		ips_nft_ruleset "$chains" | nft -f - || return 1
		return 0
	fi
	# iptables carries the rules: a table left by an earlier nft run must go,
	# or every packet would be queued twice.
	ips_nft_remove
	for tool in $(ips_tools); do
		"$tool" -w -N "$IPS_CHAIN" 2>/dev/null || true
		"$tool" -w -F "$IPS_CHAIN" || return 1
		"$tool" -w -A "$IPS_CHAIN" -j NFQUEUE --queue-num "$IPS_QUEUE_NUM" --queue-bypass || return 1
		for chain in $(ips_nfq_chains "$chains"); do
			"$tool" -w -C "$chain" -j "$IPS_CHAIN" 2>/dev/null ||
				"$tool" -w -I "$chain" 1 -j "$IPS_CHAIN" || return 1
		done
	done
	return 0
}

# ips_fw_present - DPISTACK exists in iptables.
ips_fw_present() {
	local tool
	ips_nft_present && return 0
	for tool in $(ips_tools); do
		"$tool" -w -n -L "$IPS_CHAIN" >/dev/null 2>&1 && return 0
	done
	return 1
}

# ips_fw_remove - take out every jump to DPISTACK (whatever the current
# IPS_NFQ_CHAINS says) and then the chain itself. Nothing else is touched.
ips_fw_remove() {
	local tool chain
	ips_nft_remove
	for tool in $(ips_tools); do
		for chain in "${IPS_ALL_CHAINS[@]}"; do
			while "$tool" -w -C "$chain" -j "$IPS_CHAIN" 2>/dev/null; do
				"$tool" -w -D "$chain" -j "$IPS_CHAIN" || break
			done
		done
		if "$tool" -w -n -L "$IPS_CHAIN" >/dev/null 2>&1; then
			"$tool" -w -F "$IPS_CHAIN"
			"$tool" -w -X "$IPS_CHAIN"
		fi
	done
	return 0
}

# ips_nft_present - the table "inet dpistack" exists.
ips_nft_present() {
	command -v nft >/dev/null 2>&1 && nft list table inet "$IPS_NFT_TABLE" >/dev/null 2>&1
}

# ips_nft_remove - delete our own table, and only that.
ips_nft_remove() {
	if ips_nft_present; then
		nft delete table inet "$IPS_NFT_TABLE" || return 1
	fi
	return 0
}

# --- the IPS page (tech.md 18.42): `dpistack ips status|test` ---
# Both only read. The dashboard calls the same verbs and shows their JSON,
# so the CLI and the page cannot disagree. The pcap replay of `ips test`
# writes into a private temporary directory and never touches the capture.

IPS_BLOCKED_SHOW=20
IPS_TEST_MAX_SIDS=20
IPS_DROP_ACTIONS='drop|reject|rejectsrc|rejectdst|rejectboth'

# ips_count_drop_rules <file...> - "active disabled" drop-type rules.
ips_count_drop_rules() {
	awk -v actions="$IPS_DROP_ACTIONS" '
		BEGIN { on = "^[ \t]*(" actions ")[ \t]"; off = "^[ \t]*#[ \t]*(" actions ")[ \t]" }
		$0 ~ on { e++ }
		$0 ~ off { d++ }
		END { print e + 0, d + 0 }' "$@" 2>/dev/null || echo "0 0"
}

# ips_last_stats - the IPS counters of the newest stats event, or "null".
ips_last_stats() {
	local eve line
	eve=$(path_suricata_eve_json)
	[[ -r "$eve" ]] || {
		echo null
		return 0
	}
	line=$(tail -c 4194304 "$eve" 2>/dev/null | grep -F '"event_type":"stats"' | tail -n 1)
	[[ -n "$line" ]] || {
		echo null
		return 0
	}
	printf '%s\n' "$line" | jq -c '(.stats.ips // null) as $i
		| if $i == null then null else {time: .timestamp, accepted: $i.accepted, blocked: $i.blocked, rejected: $i.rejected, replaced: $i.replaced} end' 2>/dev/null || echo null
}

# ips_last_blocked - the newest blocked alerts, newest first.
ips_last_blocked() {
	local eve
	eve=$(path_suricata_eve_json)
	[[ -r "$eve" ]] || {
		echo '[]'
		return 0
	}
	tail -c 8388608 "$eve" 2>/dev/null | grep -F '"blocked"' |
		jq -c 'select(.event_type == "alert" and .alert.action == "blocked")
			| {time: .timestamp, src: .src_ip, dest: .dest_ip, proto: .proto, sid: .alert.signature_id, msg: .alert.signature}' 2>/dev/null |
		tail -n "$IPS_BLOCKED_SHOW" | jq -sc 'reverse' 2>/dev/null || echo '[]'
}

# ips_checks <mode> <method> <pending> <remaining> - the readiness list as a
# JSON array: {id,state,text}, state ok, warn, fail or na.
ips_checks() {
	local mode="$1" method="$2" pending="$3" remaining="$4"
	local -a rows=()
	add() { rows+=("$(jq -nc --arg id "$1" --arg state "$2" --arg text "$3" '{id:$id,state:$state,text:$text}')"); }
	if [[ "$mode" == ips ]]; then
		add mode ok "Suricata is set to IPS (method $method)"
	else
		add mode na "Suricata is in IDS mode: nothing is dropped"
	fi
	if systemctl is-active --quiet suricata 2>/dev/null; then
		add suricata ok "suricata.service is running"
	elif [[ "$mode" == ips ]]; then
		add suricata fail "suricata.service is not running"
	else
		add suricata na "suricata.service is not running"
	fi
	if [[ "$method" == nfq ]]; then
		local backend
		backend=$(ips_backend)
		if [[ "$mode" != ips ]]; then
			add firewall na "the queue rules are put in when the mode goes to IPS"
		elif [[ -z "$backend" ]]; then
			add firewall fail "neither iptables nor nft is installed"
		elif ips_fw_present; then
			add firewall ok "the queue rules are in place ($backend)"
		else
			add firewall fail "the queue rules are missing ($backend): run dpistack fw apply"
		fi
		local q
		q=$(path_proc_nfqueue)
		if [[ "$mode" != ips ]]; then
			add queue na "queue $IPS_QUEUE_NUM is bound only in IPS mode"
		elif [[ -r "$q" ]] && awk -v n="$IPS_QUEUE_NUM" '$1 == n { f = 1 } END { exit !f }' "$q"; then
			add queue ok "Suricata listens on queue $IPS_QUEUE_NUM"
		else
			add queue fail "nothing listens on queue $IPS_QUEUE_NUM: traffic passes unchecked (queue-bypass)"
		fi
	else
		add firewall na "af-packet copy mode has no firewall rules"
		add queue na "af-packet copy mode has no queue"
	fi
	if [[ "$pending" == true ]]; then
		add confirm warn "waiting for mode-confirm: ${remaining} s until the rollback to IDS"
	else
		add confirm ok "no switch is waiting for a confirmation"
	fi
	printf '%s\n' "${rows[@]}" | jq -sc .
}

# ips_status [--json] - one document for the page.
ips_status() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "ips status: only --json is accepted" ;;
	esac
	command -v jq >/dev/null 2>&1 || fail 1 "ips status: jq is needed"
	local mode method deadline now remaining=0 pending=false chains
	mode=$(conf_get SURICATA_MODE ids)
	method=$(conf_get IPS_METHOD nfq)
	chains=$(conf_get IPS_NFQ_CHAINS INPUT,OUTPUT,FORWARD)
	deadline=$(mode_pending_deadline)
	if [[ -n "$deadline" ]]; then
		now=$(mode_now)
		remaining=$((deadline - now))
		((remaining < 0)) && remaining=0
		pending=true
	fi
	local e d le ld
	read -r e d < <(ips_count_drop_rules "$(path_suricata_ruleset)")
	read -r le ld < <(ips_count_drop_rules "$(path_suricata_local_rules)")
	local doc
	doc=$(jq -nc --arg mode "$mode" --arg method "$method" --arg chains "$chains" --arg backend "$(ips_backend)" \
		--argjson pending "$pending" --argjson remaining "$remaining" \
		--argjson e "${e:-0}" --argjson d "${d:-0}" --argjson le "${le:-0}" --argjson ld "${ld:-0}" \
		--argjson stats "$(ips_last_stats)" --argjson blocked "$(ips_last_blocked)" \
		--argjson checks "$(ips_checks "$mode" "$method" "$pending" "$remaining")" \
		'{mode:$mode, method:$method, chains:($chains|split(",")), backend:$backend,
		  pending:$pending, remaining_sec:$remaining,
		  drop_rules:{enabled:$e, disabled:$d, local_enabled:$le, local_disabled:$ld},
		  counters:$stats, blocked:$blocked, checks:$checks,
		  ready:($mode == "ips" and ($checks | all(.state != "fail")))}')
	if ((json)); then
		printf '%s\n' "$doc"
		return 0
	fi
	printf '%s\n' "$doc" | jq -r '
		"mode: \(.mode) (method \(.method)), ready: \(.ready)",
		(.checks[] | "  [\(.state)] \(.id): \(.text)"),
		"drop rules: \(.drop_rules.enabled) active, \(.drop_rules.disabled) disabled; local: \(.drop_rules.local_enabled) active, \(.drop_rules.local_disabled) disabled",
		(if .counters then "counters: accepted \(.counters.accepted), blocked \(.counters.blocked), rejected \(.counters.rejected), replaced \(.counters.replaced)" else "counters: no IPS counters in eve.json yet" end),
		"latest blocked: \(.blocked | length)",
		(.blocked[] | "  \(.time) \(.src) -> \(.dest) \(.proto) sid \(.sid) \(.msg)")'
}

# ips_test_rules <out> <sids|""> - writes the rules to replay into <out> and
# prints "sid state" lines for the asked sids that cannot run (disabled,
# not_found, needs_ndpi). Without sids, every active drop-type rule goes in.
ips_test_rules() {
	local out="$1" sids="$2" f plugin=0
	[[ -e "$(path_suricata_ndpi_plugin)" ]] && plugin=1
	: >"$out"
	local -a files=()
	for f in "$(path_suricata_local_rules)" "$(path_suricata_ruleset)"; do
		[[ -f "$f" ]] && files+=("$f")
	done
	((${#files[@]})) || return 0
	awk -v actions="$IPS_DROP_ACTIONS" -v sids="$sids" -v out="$out" -v plugin="$plugin" '
		BEGIN {
			n = split(sids, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1
			on = "^[ \t]*(" actions ")[ \t]"; any = "^[ \t]*(alert|pass|" actions ")[ \t]"
			off = "^[ \t]*#[ \t]*(alert|pass|" actions ")[ \t]"
		}
		function sidof(line,   s) {
			if (!match(line, /sid: *[0-9]+/)) return ""
			s = substr(line, RSTART, RLENGTH); sub(/sid: */, "", s); return s
		}
		{
			s = sidof($0); if (s == "") next
			if (sids == "") {
				if ($0 ~ on && !(s in seen)) {
					seen[s] = 1
					if ($0 ~ /ndpi-/ && !plugin) next
					print $0 >> out
				}
				next
			}
			if (!(s in want) || (s in seen)) next
			if ($0 ~ any) {
				seen[s] = 1
				if ($0 ~ /ndpi-/ && !plugin) { print s, "needs_ndpi"; next }
				print $0 >> out
			} else if ($0 ~ off) { seen[s] = 1; print s, "disabled" }
		}
		END { if (sids != "") for (k in want) if (!(k in seen)) print k, "not_found" }' "${files[@]}"
}

# ips_test [--sid N[,N...]] [--pcap NAME] [--json] - replays one of the
# shipped pcaps offline with the chosen rules (all active drop rules when no
# sid is given) and reports which would drop. --simulate-ips makes Suricata
# report a drop as "blocked" although it runs offline.
ips_test() {
	local sids="" pcap_name=bittorrent json=0
	while (($#)); do
		case "$1" in
		--sid)
			[[ $# -ge 2 ]] || fail 2 "ips test: --sid needs a list"
			sids="$2"
			shift 2
			;;
		--pcap)
			[[ $# -ge 2 ]] || fail 2 "ips test: --pcap needs a name"
			pcap_name="$2"
			shift 2
			;;
		--json)
			json=1
			shift
			;;
		*) fail 2 "ips test: unknown argument: $1" ;;
		esac
	done
	command -v jq >/dev/null 2>&1 || fail 1 "ips test: jq is needed"
	if [[ -n "$sids" ]]; then
		[[ "$sids" =~ ^[0-9]+(,[0-9]+)*$ ]] || fail 5 "ips test: --sid takes numbers separated by commas"
		(($(tr ',' '\n' <<<"$sids" | wc -l) <= IPS_TEST_MAX_SIDS)) || fail 5 "ips test: at most $IPS_TEST_MAX_SIDS sids"
	fi
	[[ "$pcap_name" =~ ^[a-z0-9_-]{1,40}$ ]] || fail 5 "ips test: the pcap name is a short word, not a path"
	local pcap="$VERIFY_DATA_DIR/$pcap_name.pcap"
	[[ -r "$pcap" ]] || fail 5 "ips test: no such pcap: $pcap_name"

	local reason=""
	if [[ "$(conf_get SURICATA_RUNTIME native)" == docker ]]; then
		reason="Suricata runs in a container: the offline replay needs a Suricata on the host"
	elif ! command -v suricata >/dev/null 2>&1; then
		reason="suricata is not installed"
	fi
	if [[ -n "$reason" ]]; then
		ips_test_emit "$json" "$(jq -nc --arg r "$reason" --arg p "$pcap_name" '{ran:false, pcap:$p, reason:$r}')"
		return 0
	fi

	local tmp skipped loaded plugins="" rc=0 out
	tmp=$(mktemp -d)
	skipped=$(ips_test_rules "$tmp/ips-test.rules" "$sids")
	loaded=$(grep -c . "$tmp/ips-test.rules" || true)
	if [[ -e "$(path_suricata_ndpi_plugin)" ]] && grep -q 'ndpi-' "$tmp/ips-test.rules"; then
		plugins=$'plugins:\n'"  - $(path_suricata_ndpi_plugin)"
	fi
	render_template "$VERIFY_TEMPLATE_DIR/suricata-test.yaml.tpl" \
		"RULE_DIR=$tmp" "RULE_FILES=  - $tmp/ips-test.rules" "PLUGINS=$plugins" >"$tmp/suricata-test.yaml" || {
		rm -rf "$tmp"
		fail 1 "ips test: could not prepare the offline configuration"
	}
	out=$(suricata -r "$pcap" -c "$tmp/suricata-test.yaml" -l "$tmp" -k none --simulate-ips 2>&1) || rc=$?
	local matched='[]'
	if [[ -f "$tmp/eve.json" ]]; then
		matched=$(jq -c 'select(.event_type == "alert") | {sid: .alert.signature_id, msg: .alert.signature, would_drop: (.alert.action == "blocked")}' "$tmp/eve.json" 2>/dev/null |
			jq -sc 'unique_by(.sid)') || matched='[]'
	fi
	rm -rf "$tmp"
	local asked='[]'
	if [[ -n "$sids" ]]; then
		asked=$(jq -nc --arg sids "$sids" --arg skipped "$skipped" --argjson m "$matched" '
			($skipped | split("\n") | map(select(. != "") | split(" ") | {key: .[0], value: .[1]}) | from_entries) as $s
			| [$sids | split(",")[] | . as $id
				| {sid: ($id | tonumber),
				   state: ($s[$id] // (($m | map(select((.sid | tostring) == $id)) | first) as $hit
					| if $hit == null then "no_match" elif $hit.would_drop then "would_drop" else "alert_only" end))}]')
	fi
	local doc
	doc=$(jq -nc --arg p "$pcap_name" --argjson loaded "$loaded" --argjson rc "$rc" --argjson m "$matched" --argjson asked "$asked" \
		--arg tail "$( ((rc != 0)) && printf '%s' "$out" | tail -n 1)" \
		'{ran:($rc == 0), pcap:$p, simulate_ips:true, loaded:$loaded, matched:$m,
		  would_drop:($m | map(select(.would_drop)) | length), requested:$asked}
		 + (if $rc != 0 then {reason:("suricata -r exited with code \($rc): " + $tail)} else {} end)')
	ips_test_emit "$json" "$doc"
	return 0
}

ips_test_emit() {
	if (($1)); then
		printf '%s\n' "$2"
		return 0
	fi
	printf '%s\n' "$2" | jq -r '
		if .ran then
			"replayed \(.pcap).pcap with \(.loaded) rules (simulated IPS): \(.would_drop) would drop, \(.matched | length) matched",
			(.matched[] | "  sid \(.sid) \(if .would_drop then "would drop" else "alert only" end): \(.msg)"),
			(.requested[]? | "  asked sid \(.sid): \(.state)")
		else "not run: \(.reason)" end'
}

# cmd_ips status|test - the verb behind the IPS page.
cmd_ips() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	status) ips_status "$@" ;;
	test) ips_test "$@" ;;
	*) fail 2 "ips: status [--json] | test [--sid N,...] [--pcap NAME] [--json]" ;;
	esac
}
