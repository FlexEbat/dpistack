#!/usr/bin/env bats
# Slice 40 (18.40), the exceptions of Suricata: `dpistack exceptions` and the
# threshold.config behind it. Criteria are listed in the entry of 18.40.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"

	# suricata -T that fails when the threshold file named in the yaml holds
	# INVALID, as the real one fails on a line it cannot parse.
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] || exit 0
yaml="$3"
thr=$(sed -n 's/^threshold-file: *//p' "$yaml")
echo "$thr" >>"${MOCK_THRESHOLD_LOG:-/dev/null}"
if [[ -z "$thr" ]]; then echo "ERROR: no threshold-file in the yaml"; exit 1; fi
if grep -q INVALID "$thr" 2>/dev/null; then
	echo "ERROR: invalid threshold line"
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

	YAML="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	THR="$DPISTACK_ROOT/etc/suricata/threshold.config"
	SOCK="$DPISTACK_ROOT/run/suricata-command.socket"
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$MOCK_CALLS_LOG"
}

today() { date -u +%Y-%m-%d; }

@test "criterion 1: the installer writes threshold.config and names it in suricata.yaml" {
	[ -f "$THR" ]
	grep -q '^# Exceptions of Suricata' "$THR"
	grep -q '^threshold-file: /etc/suricata/threshold.config$' "$YAML"
}

@test "criterion 1: a threshold.config that was edited is not touched by a second install" {
	echo 'suppress gen_id 1, sig_id 7' >>"$THR"
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	grep -qx 'suppress gen_id 1, sig_id 7' "$THR"
}

@test "criterion 2: suppress for one source address is written in Suricata's syntax with its data" {
	run "$CTL" exceptions add suppress 2001219 --track src --ip 10.0.0.5 --days 10 --note "printer scans" --by anna
	[ "$status" -eq 0 ]
	[ "$output" = "suppress:2001219:src:10.0.0.5" ]
	grep -qx 'suppress gen_id 1, sig_id 2001219, track by_src, ip 10.0.0.5' "$THR"
	exp=$(date -u -d '+10 days' +%Y-%m-%d)
	grep -qx "# dpistack: added=$(today) expires=$exp by=anna note=printer scans" "$THR"
}

@test "criterion 2: a bare SID suppress is allowed, silent for every address, and says so" {
	run "$CTL" exceptions add suppress 2001219 --never
	[ "$status" -eq 0 ]
	[[ "$output" == *"silent for every address"* ]]
	[[ "$output" == *"suppress:2001219:any:any"* ]]
	grep -qx 'suppress gen_id 1, sig_id 2001219' "$THR"
	grep -q 'expires=never' "$THR"
}

@test "criterion 2: a limit is written with count and seconds, per address of the tracked side" {
	run "$CTL" exceptions add limit 2210044 --track dst --count 5 --seconds 60 --never
	[ "$status" -eq 0 ]
	grep -qx 'threshold gen_id 1, sig_id 2210044, type limit, track by_dst, count 5, seconds 60' "$THR"
}

@test "criterion 3: no expiry is a choice: --never, and EXCEPTIONS_DEFAULT_DAYS=0 for entries with no option" {
	"$CTL" exceptions add suppress 1 --track src --ip 10.0.0.1 --never >/dev/null 2>&1
	grep -q 'expires=never' "$THR"
	run "$CTL" settings set EXCEPTIONS_DEFAULT_DAYS=0
	[ "$status" -eq 0 ]
	run "$CTL" exceptions add suppress 2 --track src --ip 10.0.0.2
	[ "$status" -eq 0 ]
	run "$CTL" exceptions list --json
	[[ "$output" == *'"default_days":0'* ]]
	[ "$(printf '%s' "$output" | python3 -c 'import sys,json;e=json.load(sys.stdin)["entries"];print(sorted(x["expires"] for x in e))')" = "['never', 'never']" ]
}

@test "criterion 3: with no option the default is EXCEPTIONS_DEFAULT_DAYS, 30 out of the box" {
	run "$CTL" exceptions add suppress 3 --track src --ip 10.0.0.3
	[ "$status" -eq 0 ]
	grep -q "expires=$(date -u -d '+30 days' +%Y-%m-%d)" "$THR"
	"$CTL" settings set EXCEPTIONS_DEFAULT_DAYS=7 >/dev/null 2>&1
	"$CTL" exceptions add suppress 4 --track src --ip 10.0.0.4 >/dev/null 2>&1
	grep -q "expires=$(date -u -d '+7 days' +%Y-%m-%d)" "$THR"
}

@test "criterion 4: list prints every entry, as text and as JSON with days_left and expired" {
	"$CTL" exceptions add suppress 11 --track src --ip 10.0.0.1 --days 3 >/dev/null 2>&1
	"$CTL" exceptions add limit 12 --track src --count 2 --seconds 30 --never >/dev/null 2>&1
	run "$CTL" exceptions list
	[ "$status" -eq 0 ]
	[[ "$output" == *"suppress:11:src:10.0.0.1"* ]]
	[[ "$output" == *"limit:12:src:any"* ]]
	run "$CTL" exceptions list --json
	got=$(printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
e = {x["id"]: x for x in d["entries"]}
a, b = e["suppress:11:src:10.0.0.1"], e["limit:12:src:any"]
print(a["days_left"], a["expired"], b["days_left"], b["expired"], b["count"], b["seconds"], d["default_days"])')
	[ "$got" = "3 False None False 2 30 30" ]
}

@test "criterion 5: prune drops only the entries past their last day and keeps hand written lines" {
	{
		echo '# a hand written note'
		echo "# dpistack: added=2020-01-01 expires=2020-02-01 by=old note=gone"
		echo 'suppress gen_id 1, sig_id 91, track by_src, ip 10.9.9.9'
		echo "# dpistack: added=2020-01-01 expires=$(date -u -d '+5 days' +%Y-%m-%d) by=old"
		echo 'suppress gen_id 1, sig_id 92, track by_src, ip 10.9.9.8'
		echo "# dpistack: added=2020-01-01 expires=never by=old"
		echo 'suppress gen_id 1, sig_id 93'
		echo 'pass ip 1.2.3.4'
	} >>"$THR"
	run "$CTL" exceptions prune
	[ "$status" -eq 0 ]
	[ "$output" = "removed 1 expired" ]
	run grep -q 'sig_id 91' "$THR"
	[ "$status" -ne 0 ]
	run grep -q 'expires=2020-02-01' "$THR"
	[ "$status" -ne 0 ]
	grep -q 'sig_id 92' "$THR"
	grep -q 'sig_id 93' "$THR"
	grep -qx '# a hand written note' "$THR"
	grep -qx 'pass ip 1.2.3.4' "$THR"
	run "$CTL" exceptions prune
	[ "$output" = "nothing expired" ]
}

@test "criterion 5: an entry on its last day is still in effect" {
	{
		echo "# dpistack: added=2020-01-01 expires=$(today) by=old"
		echo 'suppress gen_id 1, sig_id 94, track by_src, ip 10.9.9.7'
	} >>"$THR"
	run "$CTL" exceptions prune
	[ "$output" = "nothing expired" ]
	grep -q 'sig_id 94' "$THR"
}

@test "criterion 6: remove takes the entry and its data line, and only that entry" {
	"$CTL" exceptions add suppress 21 --track src --ip 10.0.0.1 --note first --never >/dev/null 2>&1
	"$CTL" exceptions add suppress 22 --track src --ip 10.0.0.2 --note second --never >/dev/null 2>&1
	run "$CTL" exceptions remove suppress:21:src:10.0.0.1
	[ "$status" -eq 0 ]
	run grep -q 'sig_id 21' "$THR"
	[ "$status" -ne 0 ]
	run grep -q 'note=first' "$THR"
	[ "$status" -ne 0 ]
	grep -q 'sig_id 22' "$THR"
	grep -q 'note=second' "$THR"
	run "$CTL" exceptions remove suppress:21:src:10.0.0.1
	[ "$status" -eq 4 ]
}

@test "criterion 7: a duplicate id is refused and the file does not change" {
	"$CTL" exceptions add suppress 31 --track src --ip 10.0.0.1 --never >/dev/null 2>&1
	before=$(cat "$THR")
	run "$CTL" exceptions add suppress 31 --track src --ip 10.0.0.1 --days 5
	[ "$status" -eq 1 ]
	[[ "$output" == *"already exists"* ]]
	[ "$(cat "$THR")" = "$before" ]
}

@test "criterion 8: every argument is checked: sid, track, address, counts, days, note, combinations" {
	for args in \
		"suppress abc" "suppress 1 --track up --ip 10.0.0.1" "suppress 1 --track src --ip 300.1.1.1" \
		"suppress 1 --track src --ip 10.0.0.1/33" "suppress 1 --track src --ip not-an-ip" \
		"suppress 1 --track src --ip 10.0.0.1 --days 0" "suppress 1 --track src --ip 10.0.0.1 --days 99999" \
		"suppress 1 --track src --ip 10.0.0.1 --days abc" "limit 1 --track src --count 0 --seconds 5" \
		"limit 1 --track src --count 5 --seconds 0" "limit 1 --track src --count 5 --seconds 999999"; do
		# shellcheck disable=SC2086
		run "$CTL" exceptions add $args
		[ "$status" -eq 5 ] || {
			echo "not refused with 5: $args ($status) $output"
			false
		}
	done
	for args in \
		"suppress 1 --track src" "suppress 1 --ip 10.0.0.1" "suppress 1 --track src --ip 10.0.0.1 --days 3 --never" \
		"suppress 1 --count 3" "limit 1 --count 5 --seconds 5" "limit 1 --track src --ip 10.0.0.1 --count 5 --seconds 5" "bogus 1"; do
		# shellcheck disable=SC2086
		run "$CTL" exceptions add $args
		[ "$status" -eq 2 ] || {
			echo "not refused with 2: $args ($status) $output"
			false
		}
	done
	run "$CTL" exceptions add suppress 1 --track src --ip 10.0.0.1 --note 'bad;note'
	[ "$status" -ne 0 ]
	run "$CTL" exceptions remove 'suppress:1:src:10.0.0.1;rm'
	[ "$status" -ne 0 ]
	run grep -q 'sig_id 1,' "$THR"
	[ "$status" -ne 0 ]
}

@test "criterion 9: a file that fails suricata -T is never written" {
	echo 'INVALID line' >>"$THR"
	before=$(cat "$THR")
	run "$CTL" exceptions add suppress 41 --track src --ip 10.0.0.1 --never
	[ "$status" -eq 3 ]
	[ "$(cat "$THR")" = "$before" ]
}

@test "criterion 10: the check sees the candidate file, not the live one" {
	log="$(mktemp)"
	export MOCK_THRESHOLD_LOG="$log"
	"$CTL" exceptions add suppress 51 --track src --ip 10.0.0.1 --never >/dev/null 2>&1
	[ -s "$log" ]
	run grep -q "$THR" "$log"
	[ "$status" -ne 0 ]
	rm -f "$log"
}

@test "criterion 11: a running Suricata is reloaded after a change, a stopped one is left alone" {
	: >"$MOCK_CALLS_LOG"
	"$CTL" exceptions add suppress 61 --track src --ip 10.0.0.1 --never >/dev/null 2>&1
	run grep -q 'suricatasc' "$MOCK_CALLS_LOG"
	[ "$status" -ne 0 ]
	mkdir -p "$(dirname "$SOCK")"
	python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$SOCK"
	"$CTL" exceptions add suppress 62 --track src --ip 10.0.0.2 --never >/dev/null 2>&1
	grep -q 'suricatasc.*ruleset-reload-nonblocking' "$MOCK_CALLS_LOG"
}

@test "criterion 12: every change is backed up and the config editor and backup know the file" {
	"$CTL" exceptions add suppress 71 --track src --ip 10.0.0.1 --never >/dev/null 2>&1
	ls "$DPISTACK_ROOT/var/lib/dpistack/backups" | grep -q 'threshold.config'
	run "$CTL" config-read threshold.config
	[ "$status" -eq 0 ]
	[[ "$output" == *"sig_id 71"* ]]
	printf '%s\n' '# edited' 'suppress gen_id 1, sig_id 72' | "$CTL" config-write threshold.config >/dev/null 2>&1
	grep -q 'sig_id 72' "$THR"
	run bash -c "printf 'INVALID\n' | '$CTL' config-write threshold.config"
	[ "$status" -eq 3 ]
	grep -q 'sig_id 72' "$THR"
}

@test "criterion 13: the usage text lists the verb and the audit log records adds and removes, not lists" {
	run "$CTL" nonsense
	[[ "$output" == *"exceptions list"* ]]
	"$CTL" exceptions add suppress 81 --track src --ip 10.0.0.1 --never >/dev/null 2>&1
	"$CTL" exceptions list >/dev/null 2>&1
	audit="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	[ "$(jq -r 'select(.action == "cli exceptions") | .target' "$audit" | tr '\n' ' ')" = "add " ]
	"$CTL" exceptions remove suppress:81:src:10.0.0.1 >/dev/null 2>&1
	[ "$(jq -r 'select(.action == "cli exceptions") | .target' "$audit" | tr '\n' ' ')" = "add remove " ]
}

@test "criterion 14: the watchdog removes an expired entry on its own run, and logs it only when it did" {
	{
		echo "# dpistack: added=2020-01-01 expires=2020-02-01 by=old"
		echo 'suppress gen_id 1, sig_id 95, track by_src, ip 10.9.9.6'
	} >>"$THR"
	audit="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	DPISTACK_BIN="$CTL" run bash "$REPO_DIR/bin/dpistack-watch"
	run grep -q 'sig_id 95' "$THR"
	[ "$status" -ne 0 ]
	[ "$(jq -r 'select(.action == "cli exceptions") | .detail' "$audit" | tr '\n' '|')" = "removed 1 expired (exit 0)|" ]
	DPISTACK_BIN="$CTL" run bash "$REPO_DIR/bin/dpistack-watch"
	[ "$(jq -r 'select(.action == "cli exceptions")' "$audit" | grep -c action)" -eq 1 ]
}
