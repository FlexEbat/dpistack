#!/usr/bin/env bats
# The settings verbs of dpistack (R159): the dashboard's structured settings
# screen reads the schema and changes keys through them.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/dpistack-ctl"
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

@test "settings list --json describes every schema key and never shows a secret" {
	printf 'ALERT_TG_TOKEN=123456:SECRETVALUE\n' >"$DPISTACK_ROOT/etc/dpistack/secrets.conf"
	run "$CTL" settings list --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.keys | length > 40' >/dev/null
	echo "$output" | jq -e '.keys[] | select(.key=="STATS_INTERVAL_SEC") | .type=="int" and .min==5 and .max==300 and .weight=="light"' >/dev/null
	echo "$output" | jq -e '.keys[] | select(.key=="SURICATA_SOURCE") | .options==["distro","oisf","source"] and .weight=="heavy"' >/dev/null
	echo "$output" | jq -e '.keys[] | select(.key=="ALERT_TG_TOKEN") | .secret==true and .set==true and .value==""' >/dev/null
	[[ "$output" != *SECRETVALUE* ]]
	# every key of the schema is there, none twice
	n=$(bash -c 'source '"$REPO_DIR"'/lib/schema.sh; echo ${#SCHEMA_KEYS[@]}')
	[ "$(echo "$output" | jq '.keys | length')" -eq "$n" ]
}

@test "settings check: a valid change is light, a source change is heavy, a bad value is an error" {
	run "$CTL" settings check STATS_INTERVAL_SEC=45
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.ok and .weight=="light" and .changed==["STATS_INTERVAL_SEC"]' >/dev/null
	run "$CTL" settings check SURICATA_SOURCE=distro
	echo "$output" | jq -e '.ok and .weight=="heavy"' >/dev/null
	run "$CTL" settings check STATS_INTERVAL_SEC=9999
	[ "$status" -eq 3 ]
	echo "$output" | jq -e '.ok==false and (.errors | length) > 0' >/dev/null
	run "$CTL" settings check NOSUCH=1
	[ "$status" -eq 5 ]
	run "$CTL" settings check ALERT_TG_TOKEN=x
	[ "$status" -eq 3 ]
}

@test "settings set --apply writes dpistack.conf and re-renders the config; no change is a no-op" {
	run "$CTL" settings set --apply STATS_INTERVAL_SEC=45
	[ "$status" -eq 0 ]
	grep -qx 'STATS_INTERVAL_SEC=45' "$CONF_FILE"
	grep -q "interval: 45" "$YAML"
	run "$CTL" settings set --apply STATS_INTERVAL_SEC=45
	[[ "$output" == *"без изменений"* ]]
}

@test "settings set without --apply only records, a heavy change without --apply-heavy is refused" {
	run "$CTL" settings set STATS_INTERVAL_SEC=60
	[ "$status" -eq 0 ]
	[[ "$output" == *"не применён"* ]]
	grep -qx 'STATS_INTERVAL_SEC=60' "$CONF_FILE"
	before="$(sha256sum "$CONF_FILE" | cut -d' ' -f1)"
	run "$CTL" settings set --apply SURICATA_SOURCE=distro
	[ "$status" -eq 3 ]
	[[ "$output" == *"--apply-heavy"* ]]
	[ "$(sha256sum "$CONF_FILE" | cut -d' ' -f1)" = "$before" ]
}

@test "settings set --apply-heavy starts the transient unit with --force, a second start is refused" {
	run "$CTL" settings set --apply-heavy SURICATA_SOURCE=distro
	[ "$status" -eq 0 ]
	[[ "$output" == *"применение запущено"* ]]
	grep -q 'systemd-run.*--unit=dpistack-apply.*reconfigure -y --force' "$MOCK_CALLS_LOG"
	! grep -q 'ACCESS_CONFIRM' "$MOCK_CALLS_LOG"
}

@test "settings set refuses a busy port with the holder and a free port, and leaves the file alone" {
	before="$(sha256sum "$CONF_FILE" | cut -d' ' -f1)"
	MOCK_SS_LISTEN=9900 MOCK_SS_PROC=nginx run "$CTL" settings set --apply PANEL_PORT=9900
	[ "$status" -eq 3 ]
	[[ "$output" == *"порт 9900 (PANEL_PORT) уже занят: nginx; свободный: 9901"* ]]
	[ "$(sha256sum "$CONF_FILE" | cut -d' ' -f1)" = "$before" ]
	MOCK_SS_LISTEN=9900 run "$CTL" settings check PANEL_PORT=9900
	echo "$output" | jq -e '.warnings[0].key=="PANEL_PORT" and .warnings[0].suggestion==9901' >/dev/null
}

@test "settings secret takes the value on stdin, writes secrets.conf 0600 and keeps it out of dpistack.conf" {
	run bash -c "printf '%s\n' '123456:ABCdef' | '$CTL' settings secret ALERT_TG_TOKEN"
	[ "$status" -eq 0 ]
	SEC="$DPISTACK_ROOT/etc/dpistack/secrets.conf"
	grep -qx 'ALERT_TG_TOKEN=123456:ABCdef' "$SEC"
	[ "$(stat -c %a "$SEC")" = "600" ]
	run grep -q 'ABCdef' "$CONF_FILE"
	[ "$status" -ne 0 ]
	run "$CTL" settings list
	[[ "$output" == *"ALERT_TG_TOKEN=(задан)"* ]]
	[[ "$output" != *ABCdef* ]]
	# not a secret key
	run bash -c "echo x | '$CTL' settings secret PANEL_PORT"
	[ "$status" -eq 5 ]
}

@test "settings job reports the unit state as JSON" {
	run "$CTL" settings job
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'has("state") and has("log")' >/dev/null
}

@test "settings check and set take KEY=VALUE lines on stdin, for values the argument check would refuse" {
	run bash -c "printf '%s\n' 'BPF_FILTER=not (host 10.0.0.1 && port 22)' | '$CTL' settings check"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.ok and .changed==["BPF_FILTER"]' >/dev/null
	run bash -c "printf '%s\n' 'BPF_FILTER=not (host 10.0.0.1 && port 22)' 'STATS_INTERVAL_SEC=50' | '$CTL' settings set --apply"
	[ "$status" -eq 0 ]
	grep -qx 'BPF_FILTER=not (host 10.0.0.1 && port 22)' "$CONF_FILE"
	grep -qx 'STATS_INTERVAL_SEC=50' "$CONF_FILE"
	# the schema pattern still holds for what comes on stdin
	run bash -c "printf '%s\n' 'BPF_FILTER=a;rm -rf /' | '$CTL' settings check"
	[ "$status" -eq 3 ]
}
