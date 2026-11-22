#!/usr/bin/env bats
# Task 57: a Suricata alert reaches the delivery channels. The watchdog reads
# what eve.json gained since the last run, so every test runs it twice: once to
# set the position, once after the alerts were added. curl and logger are
# fakes that write what they were given to files; the clock is DPISTACK_NOW.

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
	printf 'ALERT_CHANNELS=panel,log\nDETECT_NOTIFY=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
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
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN" "$LOGGER_LOG" "$CURL_LOG"
}

# alert <severity> <sid> <signature> <src> <dest> [action] - one alert line.
alert() {
	jq -nc --argjson sev "$1" --argjson sid "$2" --arg sig "$3" --arg src "$4" --arg dst "$5" --arg act "${6:-allowed}" \
		'{timestamp:"2026-11-21T10:00:00.000000+0000",event_type:"alert",src_ip:$src,src_port:51234,dest_ip:$dst,dest_port:6881,proto:"TCP",app_proto:"bittorrent",alert:{action:$act,signature_id:$sid,signature:$sig,category:"Policy",severity:$sev}}' >>"$EVE"
}

detect_lines() { grep -c 'detection' "$LOGGER_LOG" || true; }

@test "DETECT_NOTIFY=no (the default) sends nothing and keeps no position" {
	printf 'ALERT_CHANNELS=panel,log\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 2000001 "ET P2P BitTorrent" 10.0.0.5 203.0.113.7
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ ! -s "$LOGGER_LOG" ]
	[ ! -f "$STATE" ]
}

@test "the first run starts at the end of eve.json: the history is not sent" {
	alert 1 2000001 "ET P2P BitTorrent" 10.0.0.5 203.0.113.7
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ "$(detect_lines)" -eq 0 ]
	[ "$(jq -r .offset "$STATE")" -eq "$(stat -c %s "$EVE")" ]
}

@test "a new high alert is sent to the log channel with its signature, sid and flow" {
	run "$WATCH"
	alert 1 2000001 "ET P2P BitTorrent" 10.0.0.5 203.0.113.7
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ "$(detect_lines)" -eq 1 ]
	grep -q 'HIGH detection: ET P2P BitTorrent (sid 2000001, Policy) 10.0.0.5:51234 -> 203.0.113.7:6881 TCP/bittorrent' "$LOGGER_LOG"
	grep -q -- '-p daemon.err' "$LOGGER_LOG"
	# the same alert is not sent again on the next run
	run "$WATCH"
	[ "$(detect_lines)" -eq 1 ]
}

@test "DETECT_NOTIFY_SEVERITY: high sends only severity 1, medium sends 1 and 2, low sends all" {
	run "$WATCH"
	alert 1 1 "sig high" 10.0.0.1 1.1.1.1
	alert 2 2 "sig medium" 10.0.0.1 1.1.1.2
	alert 3 3 "sig low" 10.0.0.1 1.1.1.3
	run "$WATCH"
	[ "$(detect_lines)" -eq 1 ]

	: >"$LOGGER_LOG"
	rm -f "$STATE"
	printf 'ALERT_CHANNELS=panel,log\nDETECT_NOTIFY=yes\nDETECT_NOTIFY_SEVERITY=medium\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 11 "sig high" 10.0.0.1 2.2.2.1
	alert 2 12 "sig medium" 10.0.0.1 2.2.2.2
	alert 3 13 "sig low" 10.0.0.1 2.2.2.3
	run "$WATCH"
	[ "$(detect_lines)" -eq 2 ]

	: >"$LOGGER_LOG"
	rm -f "$STATE"
	printf 'ALERT_CHANNELS=panel,log\nDETECT_NOTIFY=yes\nDETECT_NOTIFY_SEVERITY=low\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 21 "sig high" 10.0.0.1 3.3.3.1
	alert 2 22 "sig medium" 10.0.0.1 3.3.3.2
	alert 3 23 "sig low" 10.0.0.1 3.3.3.3
	run "$WATCH"
	[ "$(detect_lines)" -eq 3 ]
}

@test "only alerts are sent: flow, dns and stats lines are not" {
	run "$WATCH"
	echo '{"event_type":"flow","src_ip":"10.0.0.1"}' >>"$EVE"
	echo '{"event_type":"stats","stats":{}}' >>"$EVE"
	echo 'not json at all' >>"$EVE"
	alert 1 5 "real alert" 10.0.0.1 1.1.1.1
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ "$(detect_lines)" -eq 1 ]
}

@test "the same signature, source and destination is sent once per window, a new destination is sent" {
	run "$WATCH"
	alert 1 7 "repeat" 10.0.0.1 1.1.1.1
	alert 1 7 "repeat" 10.0.0.1 1.1.1.1
	alert 1 7 "repeat" 10.0.0.1 1.1.1.2
	run "$WATCH"
	[ "$(detect_lines)" -eq 2 ]

	# after the window the same one is sent again
	alert 1 7 "repeat" 10.0.0.1 1.1.1.1
	DPISTACK_NOW=$((NOW + 3601)) run "$WATCH"
	[ "$(detect_lines)" -eq 3 ]
}

@test "DETECT_NOTIFY_DEDUP_MIN=0 sends every alert" {
	printf 'ALERT_CHANNELS=panel,log\nDETECT_NOTIFY=yes\nDETECT_NOTIFY_DEDUP_MIN=0\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 7 "repeat" 10.0.0.1 1.1.1.1
	alert 1 7 "repeat" 10.0.0.1 1.1.1.1
	run "$WATCH"
	[ "$(detect_lines)" -eq 2 ]
}

@test "the hourly limit holds the rest back and one summary says how many and which" {
	printf 'ALERT_CHANNELS=panel,log\nDETECT_NOTIFY=yes\nDETECT_NOTIFY_MAX_PER_HOUR=2\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	local i
	for i in 1 2 3 4 5; do alert 1 "$i" "ET sig number $i" 10.0.0.1 "1.1.1.$i"; done
	run "$WATCH"
	[ "$(detect_lines)" -eq 2 ]
	[ "$(jq -r .held "$STATE")" -eq 3 ]

	# still inside the hour: nothing more, no summary yet
	DPISTACK_NOW=$((NOW + 1800)) run "$WATCH"
	[ "$(detect_lines)" -eq 2 ]
	[ "$(grep -c 'were not sent' "$LOGGER_LOG")" -eq 0 ]

	# the hour turned: one summary, the counters start again
	DPISTACK_NOW=$((NOW + 3700)) run "$WATCH"
	[ "$(grep -c 'were not sent' "$LOGGER_LOG")" -eq 1 ]
	grep -q '3 more detections in the last hour were not sent (limit 2 per hour)' "$LOGGER_LOG"
	[ "$(jq -r .held "$STATE")" -eq 0 ]
	[ "$(jq -r .sent "$STATE")" -eq 0 ]
}

@test "a rotation (a new inode) is read from the start of the new file" {
	run "$WATCH"
	alert 1 1 "before" 10.0.0.1 1.1.1.1
	run "$WATCH"
	[ "$(detect_lines)" -eq 1 ]
	# logrotate moves the file and Suricata opens a new one
	mv "$EVE" "$EVE.1"
	: >"$EVE"
	alert 1 2 "after rotation" 10.0.0.1 1.1.1.2
	run "$WATCH"
	[ "$(detect_lines)" -eq 2 ]
	grep -q 'after rotation' "$LOGGER_LOG"
}

@test "a line that is still being written is left for the next run" {
	run "$WATCH"
	printf '{"event_type":"alert","src_ip":"10.0.0.1","dest_ip":"1.1.1.1","alert":{"signature_id":9,"signature":"half' >>"$EVE"
	run "$WATCH"
	[ "$(detect_lines)" -eq 0 ]
	printf ' written","category":"x","severity":1}}\n' >>"$EVE"
	run "$WATCH"
	[ "$(detect_lines)" -eq 1 ]
	grep -q 'half written' "$LOGGER_LOG"
}

@test "an alert that Suricata blocked says so" {
	run "$WATCH"
	alert 1 8 "dropped one" 10.0.0.1 1.1.1.1 blocked
	run "$WATCH"
	grep -q 'dropped one (sid 8, Policy) blocked' "$LOGGER_LOG"
}

@test "DETECT_NOTIFY_CHANNELS picks the channels; detections do not go to a channel it leaves out" {
	printf 'ALERT_CHANNELS=panel,log,webhook\nDETECT_NOTIFY=yes\nDETECT_NOTIFY_CHANNELS=webhook\nRULES_UPDATE=off\n' >"$CONF_FILE"
	echo 'ALERT_WEBHOOK_URL=https://hooks.example.com/abc' >"$SECRETS_FILE"
	run "$WATCH"
	alert 1 1 "only to the hook" 10.0.0.1 1.1.1.1
	run "$WATCH"
	[ "$(detect_lines)" -eq 0 ]
	grep -q 'only to the hook' "$CURL_LOG"
}

@test "the panel channel alone gives no delivery, and the watchdog does not fail" {
	printf 'ALERT_CHANNELS=panel\nDETECT_NOTIFY=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 1 "nobody listens" 10.0.0.1 1.1.1.1
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ ! -s "$CURL_LOG" ]
	[ ! -s "$LOGGER_LOG" ]
}

@test "webhook json: our own shape, the URL and the body travel on stdin, not in the arguments" {
	printf 'ALERT_CHANNELS=panel,webhook\nDETECT_NOTIFY=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
	echo 'ALERT_WEBHOOK_URL=https://hooks.example.com/SECRETTOKEN' >"$SECRETS_FILE"
	run "$WATCH"
	alert 1 1 "ET P2P BitTorrent" 10.0.0.5 203.0.113.7
	run "$WATCH"
	grep -q '^ARGS -sS --fail --max-time 10 -o /dev/null -K -$' "$CURL_LOG"
	[ "$(grep '^ARGS' "$CURL_LOG" | grep -c SECRETTOKEN)" -eq 0 ]
	grep -q 'url = "https://hooks.example.com/SECRETTOKEN"' "$CURL_LOG"
	grep -q 'header = "Content-Type: application/json"' "$CURL_LOG"
	local body
	body=$(sed -n 's/^data-binary = "\(.*\)"$/\1/p' "$CURL_LOG" | sed 's/\\\\/\\/g; s/\\"/"/g')
	[ "$(jq -r .host <<<"$body")" = "fake-host" ]
	[ "$(jq -r .severity <<<"$body")" = "err" ]
	[[ "$(jq -r .message <<<"$body")" == *"ET P2P BitTorrent"* ]]
}

@test "webhook slack and discord: the text goes in the field those services read" {
	printf 'ALERT_CHANNELS=panel,webhook\nDETECT_NOTIFY=yes\nALERT_WEBHOOK_FORMAT=slack\nRULES_UPDATE=off\n' >"$CONF_FILE"
	echo 'ALERT_WEBHOOK_URL=https://hooks.slack.example/T/B/X' >"$SECRETS_FILE"
	run "$WATCH"
	alert 1 1 "slack signature" 10.0.0.5 203.0.113.7
	run "$WATCH"
	grep -q 'data-binary = "{\\"text\\":\\"\[dpistack\] fake-host: HIGH detection: slack signature' "$CURL_LOG"

	: >"$CURL_LOG"
	rm -f "$STATE"
	printf 'ALERT_CHANNELS=panel,webhook\nDETECT_NOTIFY=yes\nALERT_WEBHOOK_FORMAT=discord\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 2 "discord signature" 10.0.0.5 203.0.113.8
	run "$WATCH"
	grep -q 'data-binary = "{\\"content\\":\\"\[dpistack\] fake-host: HIGH detection: discord signature' "$CURL_LOG"
}

@test "webhook ntfy: a plain text body with the title and the priority in headers" {
	printf 'ALERT_CHANNELS=panel,webhook\nDETECT_NOTIFY=yes\nALERT_WEBHOOK_FORMAT=ntfy\nRULES_UPDATE=off\n' >"$CONF_FILE"
	echo 'ALERT_WEBHOOK_URL=https://ntfy.example.com/dpistack' >"$SECRETS_FILE"
	run "$WATCH"
	alert 1 1 "ntfy signature" 10.0.0.5 203.0.113.7
	run "$WATCH"
	grep -q 'header = "Content-Type: text/plain; charset=utf-8"' "$CURL_LOG"
	grep -q 'header = "Title: dpistack: HIGH ntfy signature"' "$CURL_LOG"
	grep -q 'header = "Priority: 5"' "$CURL_LOG"
	grep -q '^data-binary = "\[dpistack\] fake-host: HIGH detection: ntfy signature' "$CURL_LOG"
}

@test "webhook without ALERT_WEBHOOK_URL reports itself and does not stop the other channels" {
	printf 'ALERT_CHANNELS=panel,webhook,log\nDETECT_NOTIFY=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 1 "still logged" 10.0.0.1 1.1.1.1
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ "$(detect_lines)" -eq 1 ]
}

@test "a webhook that fails is reported on stderr and the position still moves on" {
	printf 'ALERT_CHANNELS=panel,webhook\nDETECT_NOTIFY=yes\nRULES_UPDATE=off\n' >"$CONF_FILE"
	echo 'ALERT_WEBHOOK_URL=https://hooks.example.com/x' >"$SECRETS_FILE"
	run "$WATCH"
	alert 1 1 "lost one" 10.0.0.1 1.1.1.1
	FAKE_CURL_EXIT=22 run --separate-stderr "$WATCH"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"channel webhook: sending failed"* ]]
	[ "$(jq -r .offset "$STATE")" -eq "$(stat -c %s "$EVE")" ]
}

@test "syslog: host and port, udp by default, tcp when asked, an IPv6 target in brackets" {
	printf 'ALERT_CHANNELS=panel,syslog\nDETECT_NOTIFY=yes\nALERT_SYSLOG_TARGET=logs.example.com:1514\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 1 "to syslog" 10.0.0.1 1.1.1.1
	run "$WATCH"
	grep -q -- '-n logs.example.com -P 1514 --udp' "$LOGGER_LOG"

	: >"$LOGGER_LOG"
	rm -f "$STATE"
	printf 'ALERT_CHANNELS=panel,syslog\nDETECT_NOTIFY=yes\nALERT_SYSLOG_TARGET=logs.example.com\nALERT_SYSLOG_PROTO=tcp\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 2 "to syslog tcp" 10.0.0.1 1.1.1.1
	run "$WATCH"
	grep -q -- '-n logs.example.com -P 514 --tcp' "$LOGGER_LOG"

	: >"$LOGGER_LOG"
	rm -f "$STATE"
	printf 'ALERT_CHANNELS=panel,syslog\nDETECT_NOTIFY=yes\nALERT_SYSLOG_TARGET=[2001:db8::1]:6514\nRULES_UPDATE=off\n' >"$CONF_FILE"
	run "$WATCH"
	alert 1 3 "to syslog v6" 10.0.0.1 1.1.1.1
	run "$WATCH"
	grep -q -- '-n 2001:db8::1 -P 6514 --udp' "$LOGGER_LOG"
}

@test "health alerts use the new channels too" {
	printf 'ALERT_CHANNELS=panel,webhook\nRULES_UPDATE=off\n' >"$CONF_FILE"
	echo 'ALERT_WEBHOOK_URL=https://hooks.example.com/x' >"$SECRETS_FILE"
	run "$WATCH"
	[ ! -s "$CURL_LOG" ]
	# the first health state is ok; stop Suricata through the fake systemctl
	printf '#!/usr/bin/env bash\ncase "$1" in\nshow) echo loaded ;;\nis-active) echo inactive; exit 3 ;;\nis-enabled) exit 0 ;;\nesac\n' >"$FAKE_BIN/systemctl"
	run "$WATCH"
	grep -q 'suricata.process' "$CURL_LOG"
}

@test "config check: DETECT_NOTIFY needs a channel besides panel, webhook needs its URL, syslog its target" {
	run bash -c "source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/schema.sh'; source '$REPO_DIR/lib/config.sh'
		config_reset; config_load_defaults
		CONF[ALERT_CHANNELS]=panel; CONF[DETECT_NOTIFY]=yes
		config_validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"DETECT_NOTIFY=yes needs a delivery channel besides panel"* ]]

	run bash -c "source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/schema.sh'; source '$REPO_DIR/lib/config.sh'
		config_reset; config_load_defaults
		CONF[ALERT_CHANNELS]=panel,webhook,syslog
		config_validate"
	[ "$status" -ne 0 ]
	[[ "$output" == *"needs ALERT_WEBHOOK_URL"* ]]
	[[ "$output" == *"needs ALERT_SYSLOG_TARGET"* ]]
}
