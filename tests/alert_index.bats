#!/usr/bin/env bats
# Task 62: the alert index and the rotation of events.jsonl. The index has its
# own position in eve.json; the first run reads the last 8 MiB so nothing the
# Alert Center showed before is lost.

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
	printf 'ALERT_CHANNELS=panel,log\nALERT_INDEX=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
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
	INDEX="$DPISTACK_ROOT/var/lib/dpistack/alerts-index.json"
	EVENTS="$DPISTACK_ROOT/var/lib/dpistack/events.jsonl"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN" "$LOGGER_LOG" "$CURL_LOG"
}

# alert <ts> <sid> <signature> [severity]
alert() {
	jq -nc --arg ts "$1" --argjson sid "$2" --arg sig "$3" --argjson sev "${4:-2}" \
		'{timestamp:$ts,event_type:"alert",src_ip:"10.0.0.5",dest_ip:"203.0.113.7",alert:{signature_id:$sid,signature:$sig,category:"Policy",severity:$sev}}' >>"$EVE"
}

@test "the first run indexes what is already in eve.json, so nothing the Center showed is lost" {
	alert "2026-11-20T10:00:00.000000+0000" 2000001 "ET P2P BitTorrent"
	alert "2026-11-20T11:00:00.000000+0000" 2000001 "ET P2P BitTorrent"
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.["2000001"].count' "$INDEX")" -eq 2 ]
	[ "$(jq -r '.["2000001"].first_seen' "$INDEX")" = "2026-11-20T10:00:00.000000+0000" ]
	[ "$(jq -r '.["2000001"].last_seen' "$INDEX")" = "2026-11-20T11:00:00.000000+0000" ]
	[ "$(jq -r '.["2000001"].msg' "$INDEX")" = "ET P2P BitTorrent" ]
	[ "$(jq -r '.["2000001"].category' "$INDEX")" = "Policy" ]
}

@test "later alerts add to the entry of their rule and are not counted twice" {
	alert "2026-11-20T10:00:00.000000+0000" 2000001 "ET P2P BitTorrent"
	run "$WATCH"
	alert "2026-11-20T12:00:00.000000+0000" 2000001 "ET P2P BitTorrent" 1
	alert "2026-11-20T12:05:00.000000+0000" 2000002 "ET POLICY test" 3
	run "$WATCH"
	run "$WATCH"
	[ "$(jq -r '.["2000001"].count' "$INDEX")" -eq 2 ]
	[ "$(jq -r '.["2000001"].first_seen' "$INDEX")" = "2026-11-20T10:00:00.000000+0000" ]
	[ "$(jq -r '.["2000001"].last_seen' "$INDEX")" = "2026-11-20T12:00:00.000000+0000" ]
	[ "$(jq -r '.["2000001"].severity' "$INDEX")" -eq 1 ]
	[ "$(jq -r '.["2000002"].count' "$INDEX")" -eq 1 ]
}

@test "an old alert stays in the index when eve.json has long since lost it" {
	alert "2026-09-20T10:00:00.000000+0000" 2000009 "old and untriaged"
	run "$WATCH"
	# the file is rotated away (a new file, as logrotate leaves it) and fills with other alerts
	mv "$EVE" "$EVE.1"
	: >"$EVE"
	local i
	for i in $(seq 1 50); do alert "2026-09-21T10:00:00.000000+0000" 2000100 "busy"; done
	run "$WATCH"
	[ "$(jq -r '.["2000009"].msg' "$INDEX")" = "old and untriaged" ]
	[ "$(jq -r '.["2000100"].count' "$INDEX")" -eq 50 ]
}

@test "an entry whose last alert is older than ALERT_INDEX_DAYS is removed" {
	printf 'ALERT_CHANNELS=panel,log\nALERT_INDEX=yes\nALERT_INDEX_DAYS=10\nRULES_UPDATE=off\n' >"$CONF_FILE"
	local today old fresh
	today=$(date -u -d "@$NOW" +%Y-%m-%d)
	old=$(date -u -d "$today - 11 days" +%Y-%m-%d)
	fresh=$(date -u -d "$today - 9 days" +%Y-%m-%d)
	alert "${old}T10:00:00.000000+0000" 1 "too old"
	alert "${fresh}T10:00:00.000000+0000" 2 "recent enough"
	run "$WATCH"
	[ "$(jq -r 'has("1")' "$INDEX")" = "false" ]
	[ "$(jq -r 'has("2")' "$INDEX")" = "true" ]
}

@test "ALERT_INDEX=no keeps no index" {
	printf 'ALERT_CHANNELS=panel,log\nALERT_INDEX=no\nRULES_UPDATE=off\n' >"$CONF_FILE"
	alert "2026-11-20T10:00:00.000000+0000" 1 "x"
	run "$WATCH"
	[ ! -f "$INDEX" ]
}

@test "a rotation is read from the start of the new file and a half written line waits" {
	run "$WATCH"
	alert "2026-11-20T10:00:00.000000+0000" 1 "before"
	run "$WATCH"
	mv "$EVE" "$EVE.1"
	: >"$EVE"
	alert "2026-11-20T11:00:00.000000+0000" 2 "after rotation"
	printf '{"event_type":"alert","timestamp":"2026-11-20T11:30:00.000000+0000","alert":{"signature_id":3,"signature":"half' >>"$EVE"
	run "$WATCH"
	[ "$(jq -r 'has("2")' "$INDEX")" = "true" ]
	[ "$(jq -r 'has("3")' "$INDEX")" = "false" ]
	printf ' written","severity":2}}\n' >>"$EVE"
	run "$WATCH"
	[ "$(jq -r '.["3"].msg' "$INDEX")" = "half written" ]
}

@test "events.jsonl past 5 MiB moves to .1, older files shift, five are kept" {
	mkdir -p "$(dirname "$EVENTS")"
	head -c 5300000 /dev/zero | tr '\0' 'x' >"$EVENTS"
	local n
	for n in 1 2 3 4 5; do echo "old$n" >"$EVENTS.$n"; done
	run "$WATCH"
	[ "$(stat -c %s "$EVENTS.1")" -ge 5300000 ]
	[ "$(cat "$EVENTS.2")" = "old1" ]
	[ "$(cat "$EVENTS.5")" = "old4" ]
	# what was .5 is dropped, nothing is ever .6
	[ ! -e "$EVENTS.6" ]
	# the live file is short again and still world readable
	[ "$(stat -c %s "$EVENTS")" -lt 1000 ]
	[ "$(stat -c %a "$EVENTS")" = "644" ]
}

@test "a small events.jsonl is left alone" {
	mkdir -p "$(dirname "$EVENTS")"
	echo '{"ts":"x"}' >"$EVENTS"
	run "$WATCH"
	[ ! -e "$EVENTS.1" ]
}
