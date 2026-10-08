#!/usr/bin/env bats
# Covers slice 11 criteria 1-7 (config-read|write|revert, reconfigure,
# rules-*, iface, panel-passwd). Criterion 8 (A8) is a design note: with
# no component test mode known, evebox.yaml and ntopng.conf are only
# checked for being non-empty, and the tests below cover that.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/bin/dpistack-ctl"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"

	# suricata -T that judges by content: INVALID in the yaml or in the
	# ruleset directory named by default-rule-path fails the check.
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] || exit 0
yaml="$3"
dir=$(sed -n 's/^default-rule-path: *//p' "$yaml")
if grep -q INVALID "$yaml" "$dir/suricata.rules" 2>/dev/null; then
	echo "ERROR: invalid configuration"
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

	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	YAML="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	LOCAL_RULES="$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	BACKUPS="$DPISTACK_ROOT/var/lib/dpistack/backups"
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	mkdir -p "$(dirname "$LOCAL_RULES")"
	echo 'alert tcp any any -> any any (msg:"first"; sid:1000001;)' >"$LOCAL_RULES"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$MOCK_CALLS_LOG"
}

@test "criterion 1: a failed suricata -T leaves the file alone, code 3, output on stdout" {
	before="$(sha256sum "$YAML" | cut -d' ' -f1)"
	run bash -c "echo 'INVALID: true' | '$CTL' config-write suricata.yaml 2>/dev/null"
	[ "$status" -eq 3 ]
	[[ "$output" == *"ERROR: invalid configuration"* ]]
	[ "$(sha256sum "$YAML" | cut -d' ' -f1)" = "$before" ]
	[ ! -d "$BACKUPS" ] || ! ls "$BACKUPS" | grep -q '^suricata.yaml\.'

	# local.rules is checked inside a copy of the whole ruleset.
	run bash -c "echo 'INVALID rule' | '$CTL' config-write local.rules 2>/dev/null"
	[ "$status" -eq 3 ]
	grep -q first "$LOCAL_RULES"
}

@test "criterion 1: a failed schema check or an empty evebox.yaml also gives 3" {
	before="$(sha256sum "$CONF_FILE" | cut -d' ' -f1)"
	run bash -c "sed 's/^PANEL_PORT=.*/PANEL_PORT=notaport/' '$CONF_FILE' | '$CTL' config-write dpistack.conf 2>/dev/null"
	[ "$status" -eq 3 ]
	[[ "$output" == *"PANEL_PORT"* ]]
	[ "$(sha256sum "$CONF_FILE" | cut -d' ' -f1)" = "$before" ]

	run bash -c "printf '' | '$CTL' config-write evebox.yaml 2>/dev/null"
	[ "$status" -eq 3 ]
}

@test "criterion 1: success makes a backup and replaces the file atomically with its old mode" {
	chmod 0640 "$LOCAL_RULES"
	run bash -c "echo 'alert tcp any any -> any any (msg:\"second\"; sid:1000002;)' | '$CTL' config-write local.rules"
	[ "$status" -eq 0 ]
	grep -q second "$LOCAL_RULES"
	[ "$(stat -c %a "$LOCAL_RULES")" = "640" ]
	grep -q first "$BACKUPS"/local.rules.*
	[ -z "$(find "$(dirname "$LOCAL_RULES")" -name '.tmp.*')" ]
	[ -z "$(ls "$DPISTACK_ROOT/var/lib/dpistack/staging")" ]
}

@test "criterion 2: config-revert returns the last backup, even for two writes in one second" {
	echo 'one' | "$CTL" config-write enable.conf
	echo 'two' | "$CTL" config-write enable.conf
	echo 'three' | "$CTL" config-write enable.conf
	[ "$(cat "$DPISTACK_ROOT/etc/suricata/enable.conf")" = "three" ]

	run "$CTL" config-revert enable.conf
	[ "$status" -eq 0 ]
	[ "$(cat "$DPISTACK_ROOT/etc/suricata/enable.conf")" = "two" ]

	run "$CTL" config-revert nosuch.conf
	[ "$status" -eq 5 ]
}

@test "criterion 3: config-write dpistack.conf --apply runs reconfigure and records the result" {
	run bash -c "sed 's/^STATS_INTERVAL_SEC=.*/STATS_INTERVAL_SEC=45/' '$CONF_FILE' | '$CTL' config-write dpistack.conf --apply"
	[ "$status" -eq 0 ]
	grep -q "interval: 45" "$YAML"

	run "$CTL" reconfigure
	[ "$status" -eq 0 ]
	[[ "$output" == *"изменений нет"* ]]
}

@test "criterion 3: a heavy change is refused with code 3 and a pointer to install.sh reconfigure" {
	run bash -c "sed 's/^SURICATA_SOURCE=.*/SURICATA_SOURCE=distro/' '$CONF_FILE' | '$CTL' config-write dpistack.conf --apply"
	[ "$status" -eq 3 ]
	[[ "$output" == *"install.sh reconfigure"* ]]
	# --dry-run only prints the plan and changes nothing.
	run "$CTL" reconfigure --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"Тип изменения: heavy"* ]]
}

@test "criterion 4: a non-numeric sid and an unknown config name give 5 and run nothing" {
	run "$CTL" rules-sid disable abc
	[ "$status" -eq 5 ]
	run "$CTL" rules-sid disable '12;x'
	[ "$status" -eq 5 ]
	run "$CTL" config-read passwd
	[ "$status" -eq 5 ]
	run "$CTL" config-write ../../etc/passwd
	[ "$status" -eq 5 ]
	[ ! -e "$DPISTACK_ROOT/etc/suricata/disable.conf" ]
}

@test "criterion 4: config-read prints the current file" {
	run "$CTL" config-read local.rules
	[ "$status" -eq 0 ]
	[[ "$output" == *"first"* ]]
}

@test "criterion 5: iface add and remove change IFACES and re-render through reconfigure" {
	run "$CTL" iface add eth1
	[ "$status" -eq 0 ]
	grep -q '^IFACES=enp2s0,eth1$' "$CONF_FILE"
	grep -q "^  - interface: eth1" "$YAML"
	[ "$("$CTL" iface list | tr '\n' ' ')" = "enp2s0 eth1 " ]

	run "$CTL" iface remove eth1
	[ "$status" -eq 0 ]
	grep -q '^IFACES=enp2s0$' "$CONF_FILE"
	! grep -q "^  - interface: eth1" "$YAML"
}

@test "criterion 5: the last interface cannot be removed, an unknown one gives 5" {
	run "$CTL" iface remove enp2s0
	[ "$status" -eq 3 ]
	grep -q '^IFACES=enp2s0$' "$CONF_FILE"
	run "$CTL" iface add nosuchnic
	[ "$status" -eq 5 ]
}

@test "criterion 5: a hand-edited suricata.yaml survives iface add (rule 5.4)" {
	echo "# edited by hand" >>"$YAML"
	run "$CTL" iface add eth1
	[ "$status" -eq 0 ]
	grep -q "# edited by hand" "$YAML"
	! grep -q "^  - interface: eth1" "$YAML"
	grep -q '^IFACES=enp2s0,eth1$' "$CONF_FILE"
}

@test "criterion 5: a failed reconfigure puts dpistack.conf back" {
	# Break the rendered check: the fake suricata rejects the new yaml.
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
[[ "$1" == "-T" ]] && { echo "ERROR: rejected"; exit 1; }
exit 0
FAKE
	run "$CTL" iface add eth1
	[ "$status" -ne 0 ]
	grep -q '^IFACES=enp2s0$' "$CONF_FILE"
}

@test "criterion 6: rules-group and rules-sid edit the files the rules step uses" {
	run "$CTL" rules-group enable emerging-p2p
	[ "$status" -eq 0 ]
	grep -qx "group:emerging-p2p.rules" "$DPISTACK_ROOT/etc/suricata/enable.conf"
	run "$CTL" rules-group disable emerging-p2p
	! grep -q "emerging-p2p" "$DPISTACK_ROOT/etc/suricata/enable.conf"

	run "$CTL" rules-sid disable 2100498
	[ "$status" -eq 0 ]
	grep -qx "2100498" "$DPISTACK_ROOT/etc/suricata/disable.conf"
	run "$CTL" rules-sid enable 2100498
	! grep -q "2100498" "$DPISTACK_ROOT/etc/suricata/disable.conf"
}

@test "criterion 6: rules-sources goes through suricata-update with the step's data dir" {
	run "$CTL" rules-sources enable et/open
	[ "$status" -eq 0 ]
	grep -q "suricata-update enable-source -D $DPISTACK_ROOT/var/lib/suricata et/open" "$MOCK_CALLS_LOG"
	run "$CTL" rules-sources add-url https://example.org/my.rules
	[ "$status" -eq 0 ]
	grep -q "add-source -D $DPISTACK_ROOT/var/lib/suricata dpistack-custom-.* https://example.org/my.rules" "$MOCK_CALLS_LOG"
	run "$CTL" rules-sources enable 'a;b'
	[ "$status" -eq 5 ]
}

@test "criterion 6: rules-search finds by sid and by msg text, at most 50 rules" {
	ruleset="$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	mkdir -p "$(dirname "$ruleset")"
	{
		echo 'alert tcp any any -> any any (msg:"ET P2P BitTorrent DHT"; sid:2008581; rev:3;)'
		echo '# alert tcp any any -> any any (msg:"ET P2P commented out"; sid:2008582;)'
		for i in $(seq 1 60); do
			echo "alert tcp any any -> any any (msg:\"ET SCAN probe $i\"; sid:$((3000000 + i));)"
		done
	} >"$ruleset"

	run "$CTL" rules-search 2008581
	[ "$status" -eq 0 ]
	[ "$output" = "$(printf '2008581\tET P2P BitTorrent DHT')" ]
	run "$CTL" rules-search bittorrent
	[[ "$output" == *"2008581"* ]]
	run "$CTL" rules-search "ET P2P"
	[ "${#lines[@]}" -eq 1 ]
	run "$CTL" rules-search probe
	[ "${#lines[@]}" -eq 50 ]
}

@test "criterion 6: a failed rules-update restores the previous ruleset" {
	ruleset="$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	mkdir -p "$(dirname "$ruleset")"
	echo 'alert tcp any any -> any any (msg:"keep me"; sid:1;)' >"$ruleset"
	MOCK_SURICATA_UPDATE_FAIL=1 run "$CTL" rules-update
	[ "$status" -eq 1 ]
	grep -q "keep me" "$ruleset"
}

@test "criterion 7: panel-passwd writes an argon2id hash, 0640 root:dpistack, password never shown" {
	pw="S3cret-Pass-Word-12345"
	run bash -c "printf '%s\n' '$pw' | '$CTL' panel-passwd"
	[ "$status" -eq 0 ]
	[[ "$output" != *"$pw"* ]]
	auth="$DPISTACK_ROOT/etc/dpistack/panel.auth"
	[[ "$(cat "$auth")" == '$argon2id$'* ]]
	[ "$(stat -c %a "$auth")" = "640" ]
	grep -q "^chown root:dpistack $auth" "$MOCK_CALLS_LOG"
	! grep -q "$pw" "$MOCK_CALLS_LOG"
	! grep -rq "$pw" "$DPISTACK_ROOT/var/log" 2>/dev/null

	run bash -c "printf '\n' | '$CTL' panel-passwd"
	[ "$status" -eq 2 ]
}
