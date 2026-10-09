#!/usr/bin/env bats
# Covers slice 14 criteria 1-5: alert channels of dpistack-watch.
# curl and logger are fakes; the curl fake records its arguments and the
# config it reads from stdin separately, to prove that secrets never
# travel in the arguments.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WATCH="$REPO_DIR/bin/dpistack-watch"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	NOW=1790000000
	export DPISTACK_NOW="$NOW"
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	SECRETS_FILE="$DPISTACK_ROOT/etc/dpistack/secrets.conf"
	EVENTS="$DPISTACK_ROOT/var/lib/dpistack/events.jsonl"
	HEALTH="$DPISTACK_ROOT/var/lib/dpistack/health.json"
	mkdir -p "$(dirname "$CONF_FILE")" "$DPISTACK_ROOT/var/log/suricata" \
		"$DPISTACK_ROOT/var/lib/suricata/rules" "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	echo '{"event_type":"stats"}' >"$DPISTACK_ROOT/var/log/suricata/eve.json"
	: >"$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	touch -d "@$((NOW - 10))" "$DPISTACK_ROOT/var/log/suricata/eve.json" \
		"$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	TG_TOKEN="tok123SECRETvalue"
	SMTP_PASS="SmtpP4ssSECRET"
	cat >"$SECRETS_FILE" <<EOS
ALERT_TG_TOKEN=$TG_TOKEN
ALERT_SMTP_URL=smtp://user:$SMTP_PASS@mail.example:587
EOS
	cat >"$CONF_FILE" <<'EOC'
ALERT_CHANNELS=panel,log,tg,mail
ALERT_TG_CHAT_ID=4242
ALERT_MAIL_TO=ops@example.org
ALERT_MAIL_FROM=dpistack@example.org
EOC

	FAKE_BIN="$(mktemp -d)"
	LOGGER_LOG="$(mktemp)"
	CURL_ARGS="$(mktemp)"
	CURL_CFG="$(mktemp)"
	export LOGGER_LOG CURL_ARGS CURL_CFG
	FAKE_UNITS="suricata.service evebox.service ntopng.service redis-server.service dpistack-panel.service"
	export FAKE_UNITS
	cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
show)
	unit="${@: -1}"
	if [[ " $FAKE_UNITS " == *" $unit "* ]]; then echo loaded; else echo not-found; fi
	;;
is-active)
	if [[ " ${FAKE_STOPPED:-} " == *" ${@: -1} "* ]]; then echo inactive; exit 3; fi
	echo active
	;;
is-enabled) exit 0 ;;
esac
FAKE
	printf '#!/usr/bin/env bash\nfor p in ${FAKE_LISTEN:-5636 3000 6379 9800}; do echo "LISTEN 0 128 127.0.0.1:$p 0.0.0.0:*"; done\n' >"$FAKE_BIN/ss"
	printf '#!/usr/bin/env bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "/dev/fake 10000 5000 5000 50%% $2"\n' >"$FAKE_BIN/df"
	printf '#!/usr/bin/env bash\necho "$*" >>"$LOGGER_LOG"\n' >"$FAKE_BIN/logger"
	cat >"$FAKE_BIN/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CURL_ARGS"
# Only the alert calls (-K -) bring a config on stdin; the installer's
# own curl calls must not wait for input.
if [[ " $* " == *" -K - "* ]]; then
	cat >>"$CURL_CFG"
	echo "--" >>"$CURL_CFG"
fi
exit "${FAKE_CURL_RC:-0}"
FAKE
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_CALLS_LOG="$(mktemp)"
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_CALLS_LOG MOCK_IP_EXISTING_IFACES
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$LOGGER_LOG" "$CURL_ARGS" "$CURL_CFG" "$MOCK_CALLS_LOG"
}

# at <minutes> - run the watchdog that many minutes after NOW
at() {
	local m="$1"
	shift
	DPISTACK_NOW=$((NOW + m * 60)) run "$WATCH"
}

port_down() { FAKE_LISTEN="3000 6379 9800"; }

@test "criterion 1: ok to warn sends one message to every channel, recovery sends another" {
	at 0
	[ ! -s "$EVENTS" ]
	[ ! -s "$LOGGER_LOG" ]

	FAKE_LISTEN="3000 6379 9800" at 1
	[ "$(grep -c '"check":"evebox.port"' "$EVENTS")" -eq 1 ]
	[ "$(jq -r 'select(.check=="evebox.port") | .to' "$EVENTS")" = "warn" ]
	[ "$(grep -c 'evebox.port' "$LOGGER_LOG")" -eq 1 ]
	grep -q -- "-p daemon.warning" "$LOGGER_LOG"
	[ "$(grep -c 'api.telegram.org' "$CURL_CFG")" -eq 1 ]
	[ "$(grep -c 'smtp://' "$CURL_CFG")" -eq 1 ]
	grep -q 'chat_id=4242' "$CURL_CFG"
	grep -q 'mail-rcpt = "ops@example.org"' "$CURL_CFG"

	at 2
	[ "$(jq -r 'select(.check=="evebox.port") | .kind' "$EVENTS" | tail -1)" = "recovery" ]
	[ "$(grep -c 'api.telegram.org' "$CURL_CFG")" -eq 2 ]
	grep -q "восстановлено" "$LOGGER_LOG"
}

@test "criterion 1: a crit uses the err level in the log channel" {
	at 0
	FAKE_STOPPED="suricata.service" at 1
	grep -q -- "-p daemon.err .*suricata.process" "$LOGGER_LOG"
}

@test "criterion 2: while not ok, a repeat goes out no more often than WATCH_REPEAT_MIN" {
	echo 'WATCH_REPEAT_MIN=60' >>"$CONF_FILE"
	at 0
	FAKE_STOPPED="suricata.service" at 1
	count() { grep -c '"check":"suricata.process"' "$EVENTS"; }
	[ "$(count)" -eq 1 ]
	FAKE_STOPPED="suricata.service" at 30
	[ "$(count)" -eq 1 ]
	FAKE_STOPPED="suricata.service" at 61
	[ "$(count)" -eq 2 ]
	[ "$(jq -r 'select(.check=="suricata.process") | .kind' "$EVENTS" | tail -1)" = "repeat" ]
	FAKE_STOPPED="suricata.service" at 90
	[ "$(count)" -eq 2 ]
	FAKE_STOPPED="suricata.service" at 122
	[ "$(count)" -eq 3 ]
}

@test "criterion 2: WATCH_REPEAT_MIN=0 never repeats" {
	echo 'WATCH_REPEAT_MIN=0' >>"$CONF_FILE"
	at 0
	FAKE_STOPPED="suricata.service" at 1
	FAKE_STOPPED="suricata.service" at 500
	[ "$(grep -c '"check":"suricata.process"' "$EVENTS")" -eq 1 ]
}

@test "criterion 3: ALERT_CHANNELS=panel,tg writes no log and sends no mail" {
	sed -i 's/^ALERT_CHANNELS=.*/ALERT_CHANNELS=panel,tg/' "$CONF_FILE"
	at 0
	FAKE_STOPPED="suricata.service" at 1
	[ ! -s "$LOGGER_LOG" ]
	! grep -q 'smtp://' "$CURL_CFG"
	grep -q 'api.telegram.org' "$CURL_CFG"
	[ "$(grep -c '"check":"suricata.process"' "$EVENTS")" -eq 1 ]
}

@test "criterion 3: a failing tg does not stop events.jsonl or the other channels" {
	sed -i 's/^ALERT_CHANNELS=.*/ALERT_CHANNELS=panel,log,tg/' "$CONF_FILE"
	at 0
	FAKE_CURL_RC=22 FAKE_STOPPED="suricata.service" at 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"канал tg: отправка не удалась"* ]]
	[ "$(grep -c '"check":"suricata.process"' "$EVENTS")" -eq 1 ]
	grep -q "suricata.process" "$LOGGER_LOG"
	jq -e . "$HEALTH" >/dev/null
}

@test "criterion 4: the installer refuses tg without a token, code 2" {
	rm -f "$CONF_FILE" "$SECRETS_FILE"
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no --set ALERT_CHANNELS=panel,tg --set ALERT_TG_CHAT_ID=1
	[ "$status" -eq 2 ]
	[[ "$output" == *"ALERT_TG_TOKEN"* ]]
	[ ! -e "$DPISTACK_ROOT/etc/dpistack/dpistack.conf.new" ]
}

@test "criterion 4: the installer refuses mail without its fields and unknown channels" {
	rm -f "$CONF_FILE" "$SECRETS_FILE"
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no --set ALERT_CHANNELS=mail
	[ "$status" -eq 2 ]
	[[ "$output" == *"ALERT_SMTP_URL"* ]]
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no --set ALERT_CHANNELS=panel,sms
	[ "$status" -eq 2 ]
	[[ "$output" == *"неизвестный канал"* ]]
}

@test "criterion 4: the watchdog with tg and an empty token reports it and carries on" {
	: >"$SECRETS_FILE"
	sed -i 's/^ALERT_CHANNELS=.*/ALERT_CHANNELS=panel,log,tg/' "$CONF_FILE"
	at 0
	FAKE_STOPPED="suricata.service" at 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"канал tg: не заданы ALERT_TG_TOKEN"* ]]
	[ "$(grep -c '"check":"suricata.process"' "$EVENTS")" -eq 1 ]
	grep -q "suricata.process" "$LOGGER_LOG"
}

@test "criterion 5: secrets are in curl's stdin config only, nowhere else" {
	at 0
	FAKE_CURL_RC=22 FAKE_STOPPED="suricata.service" at 1
	all_output="$output"
	# They do reach curl, through the config on stdin.
	grep -q "$TG_TOKEN" "$CURL_CFG"
	grep -q "$SMTP_PASS" "$CURL_CFG"
	# They never appear in arguments, the journal, events or health.
	for f in "$CURL_ARGS" "$LOGGER_LOG" "$EVENTS" "$HEALTH"; do
		! grep -q "$TG_TOKEN" "$f"
		! grep -q "$SMTP_PASS" "$f"
	done
	[[ "$all_output" != *"$TG_TOKEN"* ]]
	[[ "$all_output" != *"$SMTP_PASS"* ]]
}

@test "criterion 5: --dry-run and the install log never show the token" {
	rm -f "$CONF_FILE" "$SECRETS_FILE"
	# The fake ss would report every port as taken and fail the preflight.
	export FAKE_LISTEN=" "
	run bash "$REPO_DIR/install.sh" install -y --dry-run --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no --set ALERT_CHANNELS=panel,tg \
		--set ALERT_TG_CHAT_ID=1 --set ALERT_TG_TOKEN="$TG_TOKEN"
	[ "$status" -eq 0 ]
	[[ "$output" != *"$TG_TOKEN"* ]]
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no --set ALERT_CHANNELS=panel,tg \
		--set ALERT_TG_CHAT_ID=1 --set ALERT_TG_TOKEN="$TG_TOKEN"
	[ "$status" -eq 0 ]
	[[ "$output" != *"$TG_TOKEN"* ]]
	! grep -rq "$TG_TOKEN" "$DPISTACK_ROOT/var/log" 2>/dev/null
	! grep -q "$TG_TOKEN" "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	[ "$(stat -c %a "$DPISTACK_ROOT/etc/dpistack/secrets.conf")" = "600" ]
	grep -q "$TG_TOKEN" "$DPISTACK_ROOT/etc/dpistack/secrets.conf"
}
