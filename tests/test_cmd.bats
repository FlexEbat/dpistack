#!/usr/bin/env bats
# Covers slice 12 criteria 1-6 (dpistack-ctl test, tests-last.json, the
# verify step) on stubs: suricata -r and curl are fakes that leave the
# same traces the real ones would.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/bin/dpistack-ctl"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/etc/suricata" \
		"$DPISTACK_ROOT/var/log/suricata" "$DPISTACK_ROOT/var/lib/suricata/rules" \
		"$DPISTACK_ROOT/usr/lib/suricata"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	printf 'IFACES=enp2s0\nTEST_HTTPS_URL=https://example.com\nTEST_BT_LIVE=no\n' \
		>"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	EVE="$DPISTACK_ROOT/var/log/suricata/eve.json"
	ENABLE="$DPISTACK_ROOT/etc/suricata/enable.conf"
	RULESET="$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	PLUGIN="$DPISTACK_ROOT/usr/lib/suricata/ndpi.so"
	LAST="$DPISTACK_ROOT/var/lib/dpistack/tests-last.json"
	echo '{"event_type":"stats"}' >"$EVE"

	FAKE_BIN="$(mktemp -d)"
	# suricata -r: reads the rule files named in the generated yaml and
	# alerts the way the real engine would for them; writes only to -l.
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == "-r" ]] || exit 0
yaml="" logdir=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-c) yaml="$2"; shift ;;
	-l) logdir="$2"; shift ;;
	esac
	shift
done
echo "$logdir" >>"$FAKE_LOG"
plugins=0
grep -q '^plugins:' "$yaml" && plugins=1
for f in $(sed -n 's/^  - \(\/.*rules\)$/\1/p' "$yaml"); do
	[[ -f "$f" ]] || continue
	if grep -q 'ET P2P BitTorrent' "$f"; then
		echo '{"event_type":"alert","alert":{"signature":"ET P2P BitTorrent DHT ping request","signature_id":2008581}}' >>"$logdir/eve.json"
	fi
	if ((plugins)) && grep -q 'ndpi-protocol:BitTorrent' "$f"; then
		echo '{"event_type":"alert","alert":{"signature":"dpistack test nDPI BitTorrent","signature_id":9000001}}' >>"$logdir/eve.json"
	fi
done
exit "${FAKE_SURICATA_RC:-0}"
FAKE
	cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_LOG"
if [[ -n "${FAKE_CURL_SNI:-}" && -f "$EVE" ]]; then
	echo "{\"event_type\":\"tls\",\"tls\":{\"sni\":\"$FAKE_CURL_SNI\"}}" >>"$EVE"
fi
[[ "${FAKE_CURL_RC:-0}" -ne 0 ]] && echo "curl: (6) Could not resolve host" >&2
exit "${FAKE_CURL_RC:-0}"
FAKE
	cat >"$FAKE_BIN/tcpreplay" <<'FAKE'
#!/usr/bin/env bash
echo "tcpreplay $*" >>"$FAKE_LOG"
echo '{"event_type":"alert","alert":{"signature":"ET P2P BitTorrent live"}}' >>"$EVE"
FAKE
	chmod +x "$FAKE_BIN"/*
	FAKE_LOG="$(mktemp)"
	export FAKE_LOG EVE
	DPISTACK_TEST_WAIT=2
	export DPISTACK_TEST_WAIT
	MOCK_CALLS_LOG="$(mktemp)"
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_CALLS_LOG MOCK_IP_EXISTING_IFACES
	PATH="$FAKE_BIN:$REPO_DIR/tests/mocks:$PATH"
	export PATH
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$FAKE_LOG" "$MOCK_CALLS_LOG"
}

enable_p2p() {
	echo 'group:emerging-p2p.rules' >"$ENABLE"
	echo 'alert tcp any any -> any any (msg:"ET P2P BitTorrent DHT ping request"; sid:2008581;)' >"$RULESET"
}

@test "criterion 1: bittorrent passes on the emerging-p2p group alone" {
	enable_p2p
	run "$CTL" test bittorrent --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "pass" ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"ET P2P BitTorrent"* ]]
}

@test "criterion 1: bittorrent passes on the loaded nDPI plugin alone" {
	: >"$PLUGIN"
	run "$CTL" test bittorrent --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "pass" ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"nDPI BitTorrent"* ]]
}

@test "criterion 2: neither p2p rules nor plugin gives skip with the reason, code 0" {
	run "$CTL" test bittorrent --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "skip" ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"emerging-p2p"* ]]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"NDPI_ENABLE=yes"* ]]
	[ ! -s "$FAKE_LOG" ]
}

@test "criterion 3: the main eve.json is byte-identical after test bittorrent" {
	enable_p2p
	: >"$PLUGIN"
	before="$(sha256sum "$EVE" | cut -d' ' -f1)"
	size="$(stat -c %s "$EVE")"
	run "$CTL" test bittorrent
	[ "$status" -eq 0 ]
	[ "$(stat -c %s "$EVE")" -eq "$size" ]
	[ "$(sha256sum "$EVE" | cut -d' ' -f1)" = "$before" ]
	# The replay wrote into its own temp directory, which is gone now.
	logdir="$(tail -1 "$FAKE_LOG")"
	[ "$logdir" != "$(dirname "$EVE")" ]
	[ ! -d "$logdir" ]
}

@test "criterion 3: a replay with no BitTorrent alert fails with a reason, code 1" {
	enable_p2p
	: >"$RULESET"
	run "$CTL" test bittorrent --json
	[ "$status" -eq 1 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "fail" ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"не дал алерта"* ]]
}

@test "criterion 4: https passes when curl produces a tls event with the right sni" {
	FAKE_CURL_SNI=example.com run "$CTL" test https --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "pass" ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"sni=example.com"* ]]
	grep -q "curl .*https://example.com" "$FAKE_LOG"
}

@test "criterion 4: https fails when no tls event appears, naming the capture interface problem" {
	MOCK_IP_DEFAULT_IFACE=eth9 run "$CTL" test https --json
	[ "$status" -eq 1 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "fail" ]
	detail="$(echo "$output" | jq -r '.[0].detail')"
	[[ "$detail" == *"sni=example.com"* ]]
	[[ "$detail" == *"curl идёт через eth9"* ]]
}

@test "criterion 4: an event for another host does not count" {
	FAKE_CURL_SNI=other.example run "$CTL" test https --json
	[ "$status" -eq 1 ]
	[ "$(echo "$output" | jq -r '.[0].status')" = "fail" ]
}

@test "criterion 4: a failed curl and a missing eve.json each give their own reason" {
	FAKE_CURL_RC=6 run "$CTL" test https --json
	[ "$status" -eq 1 ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"curl не прошёл (код 6)"* ]]

	rm -f "$EVE"
	run "$CTL" test https --json
	[ "$status" -eq 1 ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"не найден"* ]]
}

@test "criterion 5: tests-last.json keeps the last result of each test and replaces a re-run" {
	run "$CTL" test bittorrent
	[ "$status" -eq 0 ]
	jq -e . "$LAST" >/dev/null
	[ "$(jq -r '.results[] | select(.name=="bittorrent") | .status' "$LAST")" = "skip" ]

	FAKE_CURL_SNI=example.com run "$CTL" test https
	[ "$status" -eq 0 ]
	[ "$(jq '.results | length' "$LAST")" -eq 2 ]
	[ "$(jq -r '.results[] | select(.name=="https") | .status' "$LAST")" = "pass" ]

	enable_p2p
	run "$CTL" test bittorrent
	[ "$(jq '.results | length' "$LAST")" -eq 2 ]
	[ "$(jq -r '.results[] | select(.name=="bittorrent") | .status' "$LAST")" = "pass" ]
	[ "$(jq -r '.results[] | select(.name=="https") | .status' "$LAST")" = "pass" ]
	for f in name status detail duration_ms timestamp; do
		[ "$(jq "[.results[] | has(\"$f\")] | all" "$LAST")" = "true" ]
	done
}

@test "all runs both tests, a fail makes the code 1, skip alone keeps it 0" {
	run "$CTL" test all --json
	[ "$status" -eq 1 ]
	[ "$(echo "$output" | jq 'length')" -eq 2 ]
	[ "$(echo "$output" | jq -r '.[0].name')" = "bittorrent" ]

	enable_p2p
	FAKE_CURL_SNI=example.com run "$CTL" test all
	[ "$status" -eq 0 ]
}

@test "TEST_BT_LIVE=yes replays through tcpreplay and looks in the main eve.json" {
	enable_p2p
	sed -i 's/^TEST_BT_LIVE=.*/TEST_BT_LIVE=yes/' "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" test bittorrent --json
	[ "$status" -eq 0 ]
	[[ "$(echo "$output" | jq -r '.[0].detail')" == *"живой прогон через enp2s0"* ]]
	grep -q "tcpreplay -i enp2s0 .*bittorrent.pcap" "$FAKE_LOG"
}

@test "argument errors: unknown test 5, missing name 2, metacharacters 5" {
	run "$CTL" test nosuch
	[ "$status" -eq 5 ]
	run "$CTL" test
	[ "$status" -eq 2 ]
	run "$CTL" test 'all;touch x'
	[ "$status" -eq 5 ]
}

@test "criterion 6: install runs all tests; a failing test does not cancel the install and is reported" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"ВНИМАНИЕ: проверочные тесты не прошли"* ]]
	[[ "$output" == *"установка завершена"* ]]
	[ "$(jq '.results | length' "$LAST")" -eq 2 ]

	# Nothing re-runs on an unchanged system.
	before="$(cat "$LAST")"
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[ "$(cat "$LAST")" = "$before" ]
}

@test "criterion 6: TEST_ON_INSTALL=no runs no tests" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[ "$status" -eq 0 ]
	[ ! -e "$LAST" ]
	[[ "$output" != *"ВНИМАНИЕ"* ]]
}
