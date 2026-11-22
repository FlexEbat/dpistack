#!/usr/bin/env bats
# Task 58: the block and allow lists of hosts, `dpistack ips block|allow`.
# The entries are two lines in local.rules each; suricata -T has the last word
# before anything is written, and the file is applied like any change of
# local.rules (rules-update).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"

	# suricata -T that fails when the rule set it is given holds FAILNOW
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] || exit 0
rp=$(sed -n 's/^default-rule-path: *//p' "$3")
if grep -qs FAILNOW "$rp"/*.rules; then
	echo "ERROR: invalid rule"
	exit 1
fi
exit 0
FAKE
	chmod +x "$FAKE_BIN/suricata"
	PATH="$FAKE_BIN:$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0,eth1"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	LOCAL="$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	mkdir -p "$(dirname "$LOCAL")"
	: >"$MOCK_CALLS_LOG"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$MOCK_CALLS_LOG"
}

today() { date -u +%Y-%m-%d; }

@test "block add writes a drop rule with its data, the first sid of the range, and applies the rules" {
	run "$CTL" ips block add 198.51.100.7 --note "port scanner" --by tester
	[ "$status" -eq 0 ]
	[[ "$output" == *"block: 198.51.100.7 (sid 9100000, expires never)"* ]]
	grep -qx "# dpistack-block: added=$(today) expires=never by=tester note=port scanner" "$LOCAL"
	grep -qx 'drop ip 198.51.100.7 any <> any any (msg:"dpistack block 198.51.100.7"; sid:9100000; rev:1;)' "$LOCAL"
	grep -q 'suricata-update' "$MOCK_CALLS_LOG"
}

@test "allow writes a pass rule, and the two lists are separate" {
	run "$CTL" ips block add 198.51.100.7
	[ "$status" -eq 0 ]
	run "$CTL" ips allow add 192.0.2.0/24 --note office
	[ "$status" -eq 0 ]
	grep -qx 'pass ip 192.0.2.0/24 any <> any any (msg:"dpistack allow 192.0.2.0/24"; sid:9100001; rev:1;)' "$LOCAL"
	run "$CTL" ips block list
	[[ "$output" == *"198.51.100.7"* ]]
	[[ "$output" != *"192.0.2.0/24"* ]]
	run "$CTL" ips allow list
	[[ "$output" == *"192.0.2.0/24"* ]]
	[[ "$output" != *"198.51.100.7"* ]]
}

@test "the same address again replaces the entry, a new address takes the next sid" {
	"$CTL" ips block add 198.51.100.7 --note first
	"$CTL" ips block add 198.51.100.7 --note second
	[ "$(grep -c 'drop ip 198.51.100.7 ' "$LOCAL")" -eq 1 ]
	grep -q 'note=second' "$LOCAL"
	[ "$(grep -c 'note=first' "$LOCAL")" -eq 0 ]
	"$CTL" ips block add 203.0.113.9
	run grep -c '^drop ip ' "$LOCAL"
	[ "$output" -eq 2 ]
	# the two sids differ
	[ "$(grep -o 'sid:[0-9]*' "$LOCAL" | sort -u | wc -l)" -eq 2 ]
}

@test "list --json gives address, sid, dates, author and note" {
	"$CTL" ips block add 2001:db8::1 --days 5 --note v6 --by tester
	run "$CTL" ips block list --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.[0].address' <<<"$output")" = "2001:db8::1" ]
	[ "$(jq -r '.[0].sid' <<<"$output")" -eq 9100000 ]
	[ "$(jq -r '.[0].expires' <<<"$output")" = "$(date -u -d '+5 days' +%Y-%m-%d)" ]
	[ "$(jq -r '.[0].by' <<<"$output")" = "tester" ]
	[ "$(jq -r '.[0].note' <<<"$output")" = "v6" ]
	run "$CTL" ips allow list --json
	[ "$output" = "[]" ]
}

@test "an empty list says so" {
	run "$CTL" ips block list
	[ "$status" -eq 0 ]
	[[ "$output" == *"the block list is empty"* ]]
}

@test "remove by address and by sid; an unknown entry is exit 5" {
	"$CTL" ips block add 198.51.100.7
	"$CTL" ips block add 203.0.113.9
	run "$CTL" ips block remove 198.51.100.7
	[ "$status" -eq 0 ]
	[ "$(grep -c '^# dpistack-block' "$LOCAL")" -eq 1 ]
	[ "$(grep -c '198.51.100.7' "$LOCAL")" -eq 0 ]
	run "$CTL" ips block remove 9100001
	[ "$status" -eq 0 ]
	[ "$(grep -c '^# dpistack-block' "$LOCAL")" -eq 0 ]
	run "$CTL" ips block remove 198.51.100.7
	[ "$status" -eq 5 ]
	# an address on the allow list is not removed by the block verb
	"$CTL" ips allow add 192.0.2.5
	run "$CTL" ips block remove 192.0.2.5
	[ "$status" -eq 5 ]
	grep -q 'pass ip 192.0.2.5 ' "$LOCAL"
}

@test "--days sets the last day; prune removes what is past it and keeps the rest" {
	"$CTL" ips block add 198.51.100.7 --days 3
	"$CTL" ips block add 203.0.113.9 --never
	"$CTL" ips allow add 192.0.2.5 --days 1
	grep -q "expires=$(date -u -d '+3 days' +%Y-%m-%d)" "$LOCAL"
	# age the first and the allow entry
	sed -i "0,/expires=$(date -u -d '+3 days' +%Y-%m-%d)/s//expires=2020-01-01/" "$LOCAL"
	sed -i "s/expires=$(date -u -d '+1 days' +%Y-%m-%d)/expires=2020-01-01/" "$LOCAL"
	run "$CTL" ips block list
	[[ "$output" == *"(expired)"* ]]
	run "$CTL" ips block prune
	[ "$status" -eq 0 ]
	[[ "$output" == *"removed 1 expired"* ]]
	[ "$(grep -c '198.51.100.7' "$LOCAL")" -eq 0 ]
	grep -q '203.0.113.9' "$LOCAL"
	run "$CTL" ips allow prune
	[[ "$output" == *"removed 1 expired"* ]]
	run "$CTL" ips block prune
	[[ "$output" == *"nothing expired"* ]]
}

@test "what is not an entry of ours stays in local.rules as it is" {
	printf '# my own rules\nalert tcp any any -> any 4444 (msg:"mine"; sid:1000001; rev:1;)\n' >"$LOCAL"
	"$CTL" ips block add 198.51.100.7
	"$CTL" ips block remove 198.51.100.7
	grep -qx '# my own rules' "$LOCAL"
	grep -qx 'alert tcp any any -> any 4444 (msg:"mine"; sid:1000001; rev:1;)' "$LOCAL"
}

@test "the sid of a rule that is already there is never reused" {
	printf 'alert tcp any any -> any 4444 (msg:"mine"; sid:9100000; rev:1;)\n' >"$LOCAL"
	"$CTL" ips block add 198.51.100.7
	grep -q 'drop ip 198.51.100.7 .*sid:9100001;' "$LOCAL"
}

@test "what is not an address, loopback and a prefix that names too much are refused with exit 5 and nothing is written" {
	: >"$LOCAL"
	local bad
	for bad in 'not-an-ip' '10.0.0.256' '127.0.0.1' '::1' '0.0.0.0' '0.0.0.0/0' '10.0.0.0/7' '2001:db8::/15'; do
		run "$CTL" ips block add "$bad"
		[ "$status" -eq 5 ]
	done
	run "$CTL" ips block add 198.51.100.7 --note 'bad;note"'
	[ "$status" -eq 5 ]
	run "$CTL" ips block add 198.51.100.7 --days 0
	[ "$status" -eq 5 ]
	run "$CTL" ips block add 198.51.100.7 --days 99999
	[ "$status" -eq 5 ]
	run "$CTL" ips block add 198.51.100.7 --nonsense
	[ "$status" -eq 2 ]
	[ ! -s "$LOCAL" ]
	[ ! -s "$MOCK_CALLS_LOG" ]
}

@test "a set that suricata -T refuses is exit 3, the file is unchanged and nothing is applied" {
	printf '# before\n' >"$LOCAL"
	run "$CTL" ips block add 198.51.100.7 --note FAILNOW
	[ "$status" -eq 3 ]
	[ "$(cat "$LOCAL")" = "# before" ]
	[ ! -s "$MOCK_CALLS_LOG" ]
}

@test "in IDS mode adding a block says that a drop rule only alerts" {
	run "$CTL" ips block add 198.51.100.7
	[[ "$output" == *"IDS mode"* ]]
	run "$CTL" ips allow add 192.0.2.5
	[[ "$output" != *"IDS mode"* ]]
}

@test "ips without a known subcommand lists them" {
	run "$CTL" ips block frobnicate
	[ "$status" -eq 2 ]
	[[ "$output" == *"list [--json] | add"* ]]
	run "$CTL" ips nonsense
	[ "$status" -eq 2 ]
	[[ "$output" == *"block|allow"* ]]
}
