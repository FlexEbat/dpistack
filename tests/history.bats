#!/usr/bin/env bats
# Task 61: the history roll-up and the new device message. The watchdog reads
# what eve.json gained since the last run from its own position, so a test
# runs it once to set the position and again after events were added.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WATCH="$REPO_DIR/bin/dpistack-watch"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	NOW=1790000000
	export DPISTACK_NOW="$NOW"
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	SECRETS_FILE="$DPISTACK_ROOT/etc/dpistack/secrets.conf"
	EVE="$DPISTACK_ROOT/var/log/suricata/eve.json"
	STATE="$DPISTACK_ROOT/var/lib/dpistack/detect-notify.json"
	mkdir -p "$(dirname "$CONF_FILE")" "$(dirname "$EVE")" "$DPISTACK_ROOT/var/lib/suricata/rules"
	: >"$EVE"
	: >"$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	touch -d "@$((NOW - 10))" "$EVE" "$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	printf 'ALERT_CHANNELS=panel,log\nHISTORY_ENABLE=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
	: >"$SECRETS_FILE"

	FAKE_BIN="$(mktemp -d)"
	LOGGER_LOG="$(mktemp)"
	CURL_LOG="$(mktemp)"
	export LOGGER_LOG CURL_LOG
	cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
show) echo loaded ;;
is-active) echo active ;;
is-enabled) exit 0 ;;
esac
FAKE
	# every port is listening, so a run is healthy and sends no health alert
	printf '#!/usr/bin/env bash\necho "State Recv-Q Send-Q Local Address:Port Peer Address:Port"\nfor p in 5636 3000 6379 9800; do echo "LISTEN 0 128 127.0.0.1:$p 0.0.0.0:*"; done\n' >"$FAKE_BIN/ss"
	printf '#!/usr/bin/env bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/fake 10000 5000 5000 50%% /x"\n' >"$FAKE_BIN/df"
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$LOGGER_LOG"\n' >"$FAKE_BIN/logger"
	# curl reads its configuration from stdin (-K -): the file keeps it, and
	# the arguments are kept apart to show that no secret is on the command line.
	printf '#!/usr/bin/env bash\nprintf "ARGS %%s\\n" "$*" >>"$CURL_LOG"\ncat >>"$CURL_LOG"\nprintf -- "---\\n" >>"$CURL_LOG"\nexit "${FAKE_CURL_EXIT:-0}"\n' >"$FAKE_BIN/curl"
	printf '#!/usr/bin/env bash\necho fake-host\n' >"$FAKE_BIN/hostname"
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$PATH"
	export PATH
	HIST="$DPISTACK_ROOT/var/lib/dpistack/history"
	DEVICES="$DPISTACK_ROOT/var/lib/dpistack/devices.json"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN" "$LOGGER_LOG" "$CURL_LOG"
}

# flow <day> <src> <dest> <app> <bytes_to_server> <bytes_to_client>
flow() {
	jq -nc --arg ts "$1T10:00:00.000000+0000" --arg s "$2" --arg d "$3" --arg a "$4" --argjson bs "$5" --argjson bc "$6" \
		'{timestamp:$ts,event_type:"flow",src_ip:$s,dest_ip:$d,app_proto:(if $a == "" then null else $a end),flow:{bytes_toserver:$bs,bytes_toclient:$bc}}' >>"$EVE"
}
alert() {
	jq -nc --arg ts "$1T10:00:00.000000+0000" --argjson sid "$2" --arg sig "$3" \
		'{timestamp:$ts,event_type:"alert",src_ip:"10.0.0.5",dest_ip:"203.0.113.7",alert:{signature_id:$sid,signature:$sig,severity:2}}' >>"$EVE"
}
new_device_lines() { grep -c 'new device' "$LOGGER_LOG" || true; }

@test "HISTORY_ENABLE=no (the default) keeps nothing" {
	printf 'ALERT_CHANNELS=panel,log\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 10 20
	run "$WATCH"
	[ ! -d "$HIST" ]
	[ ! -f "$DEVICES" ]
}

@test "the first run starts at the end of eve.json: the history already in the file is not counted" {
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 10 20
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ -z "$(ls "$HIST" 2>/dev/null)" ]
	[ "$(jq -r .offset "$DPISTACK_ROOT/var/lib/dpistack/history-cursor.json")" -eq "$(stat -c %s "$EVE")" ]
}

@test "flows and alerts become a day file: totals, applications, devices and alerts" {
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 100 900
	flow 2026-11-20 10.0.0.5 198.51.100.1 http 10 90
	flow 2026-11-20 192.168.1.20 10.0.0.5 "" 5 5
	alert 2026-11-20 2000001 "ET P2P BitTorrent"
	alert 2026-11-20 2000001 "ET P2P BitTorrent"
	run "$WATCH"
	[ "$status" -eq 0 ]
	local f="$HIST/2026-11-20.json"
	[ "$(jq -r .date "$f")" = "2026-11-20" ]
	[ "$(jq -r .flows "$f")" -eq 3 ]
	[ "$(jq -r .bytes "$f")" -eq 1110 ]
	[ "$(jq -r '.apps.tls.flows' "$f")" -eq 1 ]
	[ "$(jq -r '.apps.tls.bytes' "$f")" -eq 1000 ]
	[ "$(jq -r '.apps.unknown.flows' "$f")" -eq 1 ]
	[ "$(jq -r '.devices["10.0.0.5"].flows' "$f")" -eq 3 ]
	[ "$(jq -r '.devices["10.0.0.5"].bytes' "$f")" -eq 1110 ]
	[ "$(jq -r '.devices["10.0.0.5"].apps.tls' "$f")" -eq 1 ]
	[ "$(jq -r '.devices["192.168.1.20"].flows' "$f")" -eq 1 ]
	# a public address is not a device
	[ "$(jq -r '.devices | has("203.0.113.7")' "$f")" = "false" ]
	[ "$(jq -r '.alerts["2000001"].count' "$f")" -eq 2 ]
	[ "$(jq -r '.alerts["2000001"].msg' "$f")" = "ET P2P BitTorrent" ]
}

@test "a later run adds to the same day and a new day gets its own file" {
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 100 900
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	flow 2026-11-21 10.0.0.5 203.0.113.7 tls 5 5
	run "$WATCH"
	[ "$(jq -r .flows "$HIST/2026-11-20.json")" -eq 2 ]
	[ "$(jq -r .bytes "$HIST/2026-11-20.json")" -eq 1002 ]
	[ "$(jq -r '.devices["10.0.0.5"].flows' "$HIST/2026-11-20.json")" -eq 2 ]
	[ "$(jq -r .flows "$HIST/2026-11-21.json")" -eq 1 ]
	# nothing is counted twice when the watchdog runs again
	run "$WATCH"
	[ "$(jq -r .flows "$HIST/2026-11-20.json")" -eq 2 ]
}

@test "devices.json has the first and last day of every private address" {
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	run "$WATCH"
	flow 2026-11-22 10.0.0.5 203.0.113.7 tls 1 1
	run "$WATCH"
	[ "$(jq -r '.["10.0.0.5"].first' "$DEVICES")" = "2026-11-20" ]
	[ "$(jq -r '.["10.0.0.5"].last' "$DEVICES")" = "2026-11-22" ]
	[ "$(jq -r 'has("203.0.113.7")' "$DEVICES")" = "false" ]
	[ "$(stat -c %a "$DEVICES")" = "600" ]
}

@test "DEVICE_NEW_NOTIFY: a new address is announced once, the first run only learns" {
	printf 'ALERT_CHANNELS=panel,log\nHISTORY_ENABLE=yes\nDEVICE_NEW_NOTIFY=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	run "$WATCH"
	# the first batch created devices.json: learned, not announced
	[ "$(new_device_lines)" -eq 0 ]
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	flow 2026-11-20 10.0.0.77 203.0.113.7 tls 1 1
	run "$WATCH"
	[ "$(new_device_lines)" -eq 1 ]
	grep -q 'new device on the network: 10.0.0.77' "$LOGGER_LOG"
	flow 2026-11-21 10.0.0.77 203.0.113.7 tls 1 1
	run "$WATCH"
	[ "$(new_device_lines)" -eq 1 ]
}

@test "without DEVICE_NEW_NOTIFY a new address is recorded and nothing is sent" {
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	run "$WATCH"
	flow 2026-11-20 10.0.0.77 203.0.113.7 tls 1 1
	run "$WATCH"
	[ "$(jq -r 'has("10.0.0.77")' "$DEVICES")" = "true" ]
	[ "$(new_device_lines)" -eq 0 ]
}

@test "a rotation reads the new file from its start and a half written line waits" {
	run "$WATCH"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	run "$WATCH"
	mv "$EVE" "$EVE.1"
	: >"$EVE"
	flow 2026-11-20 10.0.0.5 203.0.113.7 tls 1 1
	printf '{"event_type":"flow","timestamp":"2026-11-20T10:00:00.000000+0000","src_ip":"10.0.0.9"' >>"$EVE"
	run "$WATCH"
	[ "$(jq -r .flows "$HIST/2026-11-20.json")" -eq 2 ]
	printf ',"dest_ip":"1.1.1.1","flow":{"bytes_toserver":1,"bytes_toclient":1}}\n' >>"$EVE"
	run "$WATCH"
	[ "$(jq -r .flows "$HIST/2026-11-20.json")" -eq 3 ]
}

@test "days older than HISTORY_DAYS are removed, newer ones stay" {
	printf 'ALERT_CHANNELS=panel,log\nHISTORY_ENABLE=yes\nHISTORY_DAYS=30\nRULES_UPDATE=off\n' >"$CONF_FILE"
	mkdir -p "$HIST"
	local today old new
	today=$(date -u -d "@$NOW" +%Y-%m-%d)
	old=$(date -u -d "$today - 31 days" +%Y-%m-%d)
	new=$(date -u -d "$today - 29 days" +%Y-%m-%d)
	echo '{}' >"$HIST/$old.json"
	echo '{}' >"$HIST/$new.json"
	run "$WATCH"
	run "$WATCH"
	[ ! -e "$HIST/$old.json" ]
	[ -e "$HIST/$new.json" ]
}

@test "config check: DEVICE_NEW_NOTIFY needs HISTORY_ENABLE" {
	run bash -c "source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/schema.sh'; source '$REPO_DIR/lib/config.sh'
		config_reset; config_load_defaults
		CONF[DEVICE_NEW_NOTIFY]=yes
		config_validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"DEVICE_NEW_NOTIFY=yes needs HISTORY_ENABLE=yes"* ]]
}
