#!/usr/bin/env bats
# Task 60: `dpistack pcap analyze FILE`. suricata is a fake: given -r FILE -c
# CONFIG -l DIR it writes an eve.json into DIR, as the real one does, and
# records the configuration it was given so the tests can read what the
# replay was told.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/etc/suricata" "$DPISTACK_ROOT/var/lib/suricata/rules" "$DPISTACK_ROOT/var/log/suricata"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	echo 'alert tcp any any -> any any (msg:"x"; sid:1; rev:1;)' >"$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	echo '# exceptions' >"$DPISTACK_ROOT/etc/suricata/threshold.config"
	: >"$DPISTACK_ROOT/var/log/suricata/eve.json"
	WORK="$(mktemp -d)"
	SEEN="$WORK/seen"
	export SEEN
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
while (($#)); do
	case "$1" in
	-r) pcap="$2"; shift 2 ;;
	-c) cfg="$2"; shift 2 ;;
	-l) dir="$2"; shift 2 ;;
	*) shift ;;
	esac
done
{ echo "pcap=$pcap"; echo "dir=$dir"; cat "$cfg"; } >"$SEEN"
[[ -n "${FAKE_SURICATA_FAIL:-}" ]] && { echo "Error: boom" >&2; exit 1; }
cat >"$dir/eve.json" <<'EVE'
{"event_type":"alert","src_ip":"10.0.0.5","src_port":51234,"dest_ip":"203.0.113.7","dest_port":6881,"alert":{"signature_id":2000001,"signature":"ET P2P BitTorrent","severity":2,"action":"allowed"}}
{"event_type":"alert","src_ip":"10.0.0.5","src_port":51235,"dest_ip":"203.0.113.8","dest_port":6881,"alert":{"signature_id":2000001,"signature":"ET P2P BitTorrent","severity":2,"action":"allowed"}}
{"event_type":"alert","src_ip":"10.0.0.9","src_port":40000,"dest_ip":"198.51.100.1","dest_port":80,"alert":{"signature_id":2000002,"signature":"ET POLICY test","severity":3,"action":"allowed"}}
{"event_type":"flow","app_proto":"tls","flow":{"bytes_toserver":1000,"bytes_toclient":9000,"pkts_toserver":10,"pkts_toclient":12}}
{"event_type":"flow","app_proto":"tls","flow":{"bytes_toserver":100,"bytes_toclient":900,"pkts_toserver":2,"pkts_toclient":2}}
{"event_type":"flow","app_proto":"http","flow":{"bytes_toserver":50,"bytes_toclient":50,"pkts_toserver":1,"pkts_toclient":1}}
{"event_type":"flow","flow":{"bytes_toserver":10,"bytes_toclient":0,"pkts_toserver":1,"pkts_toclient":0}}
EVE
exit 0
FAKE
	chmod +x "$FAKE_BIN/suricata"
	PATH="$FAKE_BIN:$REPO_DIR/tests/mocks:$PATH"
	export PATH
	# a classic little-endian pcap header and some bytes
	printf '\xd4\xc3\xb2\xa1\x02\x00\x04\x00%0100d' 0 >"$WORK/good.pcap"
}

teardown() { rm -rf "$DPISTACK_ROOT" "$WORK" "$FAKE_BIN"; }

@test "analyze reports alerts grouped by rule and protocols grouped by name, most frequent first" {
	run "$CTL" pcap analyze "$WORK/good.pcap" --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = "true" ]
	[ "$(jq -r .file <<<"$output")" = "good.pcap" ]
	[ "$(jq -r '.alerts | length' <<<"$output")" -eq 2 ]
	[ "$(jq -r '.alerts[0].sid' <<<"$output")" -eq 2000001 ]
	[ "$(jq -r '.alerts[0].count' <<<"$output")" -eq 2 ]
	[ "$(jq -r '.alerts[1].sid' <<<"$output")" -eq 2000002 ]
	[ "$(jq -r '.protocols[0].app_proto' <<<"$output")" = "tls" ]
	[ "$(jq -r '.protocols[0].flows' <<<"$output")" -eq 2 ]
	[ "$(jq -r '.protocols[0].bytes' <<<"$output")" -eq 11000 ]
	[ "$(jq -r '[.protocols[].app_proto] | sort | join(",")' <<<"$output")" = "http,tls,unknown" ]
	[ "$(jq -r .flows <<<"$output")" -eq 4 ]
	[ "$(jq -r .packets <<<"$output")" -eq 29 ]
}

@test "the plain text names the file, the counts, the alerts and the protocols" {
	run "$CTL" pcap analyze "$WORK/good.pcap"
	[ "$status" -eq 0 ]
	[[ "$output" == *"analyzed good.pcap"* ]]
	[[ "$output" == *"4 flows"* ]]
	[[ "$output" == *"sid 2000001  x2  severity 2  ET P2P BitTorrent"* ]]
	[[ "$output" == *"tls  2 flows, 11000 bytes"* ]]
}

@test "the replay uses the live rules and exceptions, the real HOME_NET and a private directory, never the live logs" {
	printf 'HOME_NET=[10.1.0.0/16]\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" pcap analyze "$WORK/good.pcap"
	[ "$status" -eq 0 ]
	grep -q "^pcap=$WORK/good.pcap" "$SEEN"
	grep -q "$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules" "$SEEN"
	grep -q "threshold-file: $DPISTACK_ROOT/etc/suricata/threshold.config" "$SEEN"
	grep -q 'HOME_NET: "\[10.1.0.0/16\]"' "$SEEN"
	# the -l directory is a temp one and it is gone
	local dir
	dir=$(sed -n 's/^dir=//p' "$SEEN")
	[[ "$dir" != "$DPISTACK_ROOT/var/log/suricata"* ]]
	[ ! -e "$dir" ]
	[ ! -s "$DPISTACK_ROOT/var/log/suricata/eve.json" ]
}

@test "a pcapng file is accepted by its first bytes" {
	printf '\x0a\x0d\x0d\x0a%0100d' 0 >"$WORK/ng.bin"
	run "$CTL" pcap analyze "$WORK/ng.bin" --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = "true" ]
}

@test "what is not a capture is refused with exit 5 whatever its name, and a missing, empty or too big file too" {
	printf 'GET / HTTP/1.1\r\n%0100d' 0 >"$WORK/fake.pcap"
	run "$CTL" pcap analyze "$WORK/fake.pcap"
	[ "$status" -eq 5 ]
	[[ "$output" == *"not a pcap or pcapng file"* ]]
	run "$CTL" pcap analyze "$WORK/none.pcap"
	[ "$status" -eq 5 ]
	: >"$WORK/empty.pcap"
	run "$CTL" pcap analyze "$WORK/empty.pcap"
	[ "$status" -eq 5 ]
	[[ "$output" == *"empty"* ]]
	printf 'PCAP_MAX_MB=1\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	{
		cat "$WORK/good.pcap"
		head -c 1100000 /dev/zero
	} >"$WORK/big.pcap"
	run "$CTL" pcap analyze "$WORK/big.pcap"
	[ "$status" -eq 5 ]
	[[ "$output" == *"the limit is 1 MiB (PCAP_MAX_MB)"* ]]
	run "$CTL" pcap analyze "$WORK"
	[ "$status" -eq 5 ]
	[ ! -e "$SEEN" ]
}

@test "usage mistakes are exit 2" {
	run "$CTL" pcap
	[ "$status" -eq 2 ]
	run "$CTL" pcap analyze
	[ "$status" -eq 2 ]
	run "$CTL" pcap analyze "$WORK/good.pcap" --nonsense
	[ "$status" -eq 2 ]
	run "$CTL" pcap analyze "$WORK/good.pcap" "$WORK/good.pcap"
	[ "$status" -eq 2 ]
}

@test "without a rule set, without suricata or in a container nothing runs, and it says why (exit 0)" {
	rm "$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	run "$CTL" pcap analyze "$WORK/good.pcap" --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = "false" ]
	[[ "$(jq -r .reason <<<"$output")" == *"no rule set yet"* ]]
	echo x >"$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	printf 'SURICATA_RUNTIME=docker\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" pcap analyze "$WORK/good.pcap" --json
	[[ "$(jq -r .reason <<<"$output")" == *"container"* ]]
	[ ! -e "$SEEN" ]
}

@test "a failing suricata is ran:false with its last line, and the temp directory is still removed" {
	FAKE_SURICATA_FAIL=1 run "$CTL" pcap analyze "$WORK/good.pcap" --json
	[ "$status" -eq 0 ]
	[ "$(jq -r .ran <<<"$output")" = "false" ]
	[[ "$(jq -r .reason <<<"$output")" == *"exited with code 1: Error: boom"* ]]
	[ ! -e "$(sed -n 's/^dir=//p' "$SEEN")" ]
}

@test "the nginx server lets the capture upload through: 512m body, no buffering, long timeouts" {
	run bash -c "grep -A8 'location = /api/pcap/analyze' '$REPO_DIR/templates/nginx.conf.tpl'"
	[[ "$output" == *"client_max_body_size 512m;"* ]]
	[[ "$output" == *"proxy_request_buffering off;"* ]]
	[[ "$output" == *"proxy_read_timeout 900s;"* ]]
}
