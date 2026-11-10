#!/usr/bin/env bats
# Slice 42 (18.42), the IPS page: `ips status` and `ips test`. Suricata is a
# stub that writes the alerts a real offline run would write for the rules it
# is given; the stub is not the real engine (see "Open" in 18.42).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
# -T: accept. -r <pcap> -c <yaml> -l <dir> -k none [--simulate-ips]: one alert
# per rule in the rule file; "blocked" for a drop rule with --simulate-ips.
[[ "$1" == "-T" ]] && exit 0
[[ -n "${FAKE_SURICATA_LOG:-}" ]] && echo "$*" >>"$FAKE_SURICATA_LOG"
[[ "${FAKE_SURICATA_FAIL:-}" == 1 ]] && { echo "Error: engine failed" >&2; exit 1; }
sim=0 dir="" yaml=""
while (($#)); do
	case "$1" in
	--simulate-ips) sim=1 ;;
	-l) dir="$2"; shift ;;
	-c) yaml="$2"; shift ;;
	esac
	shift
done
rules=$(sed -n 's/^  - //p' "$yaml" | grep 'rules$' | head -1)
: >"$dir/eve.json"
while IFS= read -r line; do
	[[ -n "$line" ]] || continue
	sid=$(sed -E 's/.*sid: *([0-9]+).*/\1/' <<<"$line")
	msg=$(sed -E 's/.*msg:"([^"]*)".*/\1/' <<<"$line")
	action=allowed
	[[ "$line" == drop* || "$line" == reject* ]] && ((sim)) && action=blocked
	printf '{"event_type":"alert","alert":{"action":"%s","signature_id":%s,"signature":"%s"}}\n' "$action" "$sid" "$msg" >>"$dir/eve.json"
done <"$rules"
exit 0
FAKE
	chmod +x "$FAKE_BIN/suricata"
	PATH="$FAKE_BIN:$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	MERGED="$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	LOCAL="$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	EVE="$DPISTACK_ROOT/var/log/suricata/eve.json"
	mkdir -p "$(dirname "$MERGED")" "$(dirname "$LOCAL")" "$(dirname "$EVE")"
	CONF="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$MOCK_CALLS_LOG"
}

setconf() { # <KEY> <value>: the config keeps the first match, so replace it
	sed -i "/^$1=/d" "$CONF"
	printf '%s=%s\n' "$1" "$2" >>"$CONF"
}

rule() { # <action> <sid> <msg> [disabled]
	local pre=""
	[[ "${4:-}" == disabled ]] && pre="# "
	printf '%s%s tcp any any -> any any (msg:"%s"; sid:%s; rev:1;)\n' "$pre" "$1" "$3" "$2"
}

fixture_rules() {
	{
		rule alert 1000001 "ET alert one"
		rule drop 1000002 "ET drop two"
		rule drop 1000003 "ET drop three" disabled
		rule reject 1000004 "ET reject four"
	} >"$MERGED"
	rule drop 9000001 "local drop" >"$LOCAL"
}

@test "ips status: ids mode is not ready, drop rules are counted per file" {
	fixture_rules
	run "$CTL" ips status --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .mode <<<"$output")" = ids ]
	[ "$(jq -r .ready <<<"$output")" = false ]
	[ "$(jq -r .drop_rules.enabled <<<"$output")" = 2 ]
	[ "$(jq -r .drop_rules.disabled <<<"$output")" = 1 ]
	[ "$(jq -r .drop_rules.local_enabled <<<"$output")" = 1 ]
	[ "$(jq -r '.checks[] | select(.id=="mode") | .state' <<<"$output")" = na ]
	[ "$(jq -r '.checks[] | select(.id=="confirm") | .state' <<<"$output")" = ok ]
}

@test "ips status: ips mode with no queue and no chain fails the checks" {
	setconf SURICATA_MODE ips
	run "$CTL" ips status --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .mode <<<"$output")" = ips ]
	[ "$(jq -r .ready <<<"$output")" = false ]
	[ "$(jq -r '.checks[] | select(.id=="queue") | .state' <<<"$output")" = fail ]
}

@test "ips status: a queue that Suricata listens on passes" {
	setconf SURICATA_MODE ips
	mkdir -p "$DPISTACK_ROOT/proc/net/netfilter"
	printf '    0  1234     0  2 65531     0     0        7  1\n' >"$DPISTACK_ROOT/proc/net/netfilter/nfnetlink_queue"
	run "$CTL" ips status --json
	[ "$(jq -r '.checks[] | select(.id=="queue") | .state' <<<"$output")" = ok ]
}

@test "ips status: afpacket has no firewall and no queue" {
	setconf SURICATA_MODE ips
	setconf IPS_METHOD afpacket
	run "$CTL" ips status --json
	[ "$(jq -r '.checks[] | select(.id=="firewall") | .state' <<<"$output")" = na ]
	[ "$(jq -r '.checks[] | select(.id=="queue") | .state' <<<"$output")" = na ]
}

@test "ips status: a pending switch shows the seconds left" {
	printf 'deadline=%s\n' "$(($(date +%s) + 90))" >"$DPISTACK_ROOT/var/lib/dpistack/mode.pending"
	run "$CTL" ips status --json
	[ "$(jq -r .pending <<<"$output")" = true ]
	[ "$(jq -r '.remaining_sec > 0' <<<"$output")" = true ]
	[ "$(jq -r '.checks[] | select(.id=="confirm") | .state' <<<"$output")" = warn ]
}

@test "ips status: counters come from the newest stats event, none gives null" {
	run "$CTL" ips status --json
	[ "$(jq -r .counters <<<"$output")" = null ]
	{
		echo '{"timestamp":"t1","event_type":"stats","stats":{"ips":{"accepted":1,"blocked":2,"rejected":3,"replaced":4}}}'
		echo '{"timestamp":"t2","event_type":"stats","stats":{"ips":{"accepted":10,"blocked":20,"rejected":30,"replaced":40}}}'
	} >"$EVE"
	run "$CTL" ips status --json
	[ "$(jq -r .counters.blocked <<<"$output")" = 20 ]
	[ "$(jq -r .counters.time <<<"$output")" = t2 ]
}

@test "ips status: only blocked alerts, newest first, 20 at most" {
	for i in $(seq 1 25); do
		printf '{"timestamp":"t%02d","event_type":"alert","src_ip":"10.0.0.1","dest_ip":"10.0.0.2","proto":"TCP","alert":{"action":"blocked","signature_id":%d,"signature":"blocked %d"}}\n' "$i" "$i" "$i"
	done >"$EVE"
	printf '{"timestamp":"t99","event_type":"alert","alert":{"action":"allowed","signature_id":99,"signature":"allowed one"}}\n' >>"$EVE"
	run "$CTL" ips status --json
	[ "$(jq -r '.blocked | length' <<<"$output")" = 20 ]
	[ "$(jq -r '.blocked[0].sid' <<<"$output")" = 25 ]
	[ "$(jq -r '[.blocked[].sid] | index(99)' <<<"$output")" = null ]
}

@test "ips status: the plain text prints the checks and the counts" {
	fixture_rules
	run "$CTL" ips status
	[ "$status" -eq 0 ]
	[[ "$output" == *"mode: ids"* && "$output" == *"drop rules: 2 active, 1 disabled"* ]]
	run "$CTL" ips status --nope
	[ "$status" -eq 2 ]
}

@test "ips test: all active drop rules are replayed in simulated IPS mode" {
	fixture_rules
	FAKE_SURICATA_LOG="$(mktemp)"
	export FAKE_SURICATA_LOG
	run "$CTL" ips test --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = true ]
	[ "$(jq -r .loaded <<<"$output")" = 3 ]
	[ "$(jq -r .would_drop <<<"$output")" = 3 ]
	grep -q -- '--simulate-ips' "$FAKE_SURICATA_LOG"
	grep -q -- '-k none' "$FAKE_SURICATA_LOG"
}

@test "ips test: named sids say would drop, alert only, disabled and not found" {
	fixture_rules
	run "$CTL" ips test --sid 1000001,1000002,1000003,5 --json
	[ "$status" -eq 0 ]
	state() { jq -r --argjson s "$1" '.requested[] | select(.sid==$s) | .state' <<<"$output"; }
	[ "$(state 1000001)" = alert_only ]
	[ "$(state 1000002)" = would_drop ]
	[ "$(state 1000003)" = disabled ]
	[ "$(state 5)" = not_found ]
	[ "$(jq -r .would_drop <<<"$output")" = 1 ]
}

@test "ips test: a rule of the local file is found too" {
	fixture_rules
	run "$CTL" ips test --sid 9000001 --json
	[ "$(jq -r '.requested[0].state' <<<"$output")" = would_drop ]
}

@test "ips test: the capture's eve.json is never touched" {
	fixture_rules
	echo '{"event_type":"stats"}' >"$EVE"
	before=$(sha256sum "$EVE")
	run "$CTL" ips test --json
	[ "$status" -eq 0 ]
	[ "$before" = "$(sha256sum "$EVE")" ]
}

@test "ips test: bad arguments are refused with code 5 or 2" {
	run "$CTL" ips test --sid abc
	[ "$status" -eq 5 ]
	run "$CTL" ips test --sid "1;rm"
	[ "$status" -eq 5 ]
	run "$CTL" ips test --sid "$(seq -s, 1 21)"
	[ "$status" -eq 5 ]
	run "$CTL" ips test --pcap ../etc/passwd
	[ "$status" -eq 5 ]
	run "$CTL" ips test --pcap nothere
	[ "$status" -eq 5 ]
	run "$CTL" ips test --bogus
	[ "$status" -eq 2 ]
	run "$CTL" ips frobnicate
	[ "$status" -eq 2 ]
}

@test "ips test: a container Suricata or a missing one is reported, not run" {
	setconf SURICATA_RUNTIME docker
	run "$CTL" ips test --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = false ]
	[[ "$(jq -r .reason <<<"$output")" == *container* ]]
}

@test "ips test: an engine failure is reported with its last line" {
	fixture_rules
	FAKE_SURICATA_FAIL=1 run "$CTL" ips test --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = false ]
	[[ "$(jq -r .reason <<<"$output")" == *"engine failed"* ]]
}

@test "ips test and ips status are not audited, they only read" {
	fixture_rules
	AUDIT="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	# a control: an audited verb does write to this file, so an empty file below means something
	"$CTL" alerts ack sid:1 >/dev/null 2>&1 || true
	"$CTL" mode ids >/dev/null 2>&1 || true
	[ -s "$AUDIT" ]
	: >"$AUDIT"
	run "$CTL" ips status --json
	run "$CTL" ips test --json
	[ ! -s "$AUDIT" ]
}

@test "ips status: a broken line in eve.json hides neither the counters nor the blocked events" {
	{
		echo '{"timestamp":"t0","event_type":"stats","stats":{"ips":{"accepted":1'
		echo '{"timestamp":"t1","event_type":"stats","stats":{"ips":{"accepted":10,"blocked":20,"rejected":30,"replaced":40}}}'
		echo '{"timestamp":"t2","event_type":"alert","alert":{"action":"blocked","signature_id":5,"signature":"b"'
		echo '{"timestamp":"t3","event_type":"alert","src_ip":"1.1.1.1","dest_ip":"2.2.2.2","proto":"TCP","alert":{"action":"blocked","signature_id":6,"signature":"six"}}'
	} >"$EVE"
	run "$CTL" ips status --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .counters.blocked <<<"$output")" = 20 ]
	[ "$(jq -r '.blocked | length' <<<"$output")" = 1 ]
	[ "$(jq -r '.blocked[0].sid' <<<"$output")" = 6 ]
}
