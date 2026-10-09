#!/usr/bin/env bats
# Covers slice 13 criteria 1-8: dpistack-watch and `dpistack-ctl health`.
# systemctl, ss and df are fakes; the clock is pinned with DPISTACK_NOW
# and file ages are set with touch, so threshold edges are exact.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WATCH="$REPO_DIR/bin/dpistack-watch"
	CTL="$REPO_DIR/bin/dpistack-ctl"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	NOW=1790000000
	export DPISTACK_NOW="$NOW"
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	EVE="$DPISTACK_ROOT/var/log/suricata/eve.json"
	RULES="$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	HEALTH="$DPISTACK_ROOT/var/lib/dpistack/health.json"
	EVENTS="$DPISTACK_ROOT/var/lib/dpistack/events.jsonl"
	mkdir -p "$(dirname "$CONF_FILE")" "$(dirname "$EVE")" "$(dirname "$RULES")" \
		"$DPISTACK_ROOT/var/lib/evebox"
	: >"$CONF_FILE"
	echo '{"event_type":"stats"}' >"$EVE"
	: >"$RULES"
	touch -d "@$((NOW - 10))" "$EVE" "$RULES"

	FAKE_BIN="$(mktemp -d)"
	CALLS="$(mktemp)"
	export CALLS
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
	if [[ " ${FAKE_FAILED:-} " == *" ${@: -1} "* ]]; then echo failed; exit 3; fi
	if [[ " ${FAKE_STOPPED:-} " == *" ${@: -1} "* ]]; then echo inactive; exit 3; fi
	echo active
	;;
is-enabled) exit 0 ;;
*) echo "systemctl $*" >>"$CALLS" ;;
esac
FAKE
	# ss -ltn: listens on the ports named in FAKE_LISTEN.
	cat >"$FAKE_BIN/ss" <<'FAKE'
#!/usr/bin/env bash
echo "State Recv-Q Send-Q Local Address:Port Peer Address:Port"
for p in ${FAKE_LISTEN:-5636 3000 6379 9800}; do
	echo "LISTEN 0 128 127.0.0.1:$p 0.0.0.0:*"
done
FAKE
	# df -P <dir>: 10000 blocks total; the free share comes from the
	# variable named after the directory (suricata log dir or evebox data).
	cat >"$FAKE_BIN/df" <<'FAKE'
#!/usr/bin/env bash
dir="${@: -1}"
avail=5000
[[ "$dir" == *suricata* ]] && avail="${FAKE_DF_SURICATA:-5000}"
[[ "$dir" == *evebox* ]] && avail="${FAKE_DF_EVEBOX:-5000}"
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 10000 $((10000 - avail)) $avail 50% $dir"
FAKE
	printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/logger"
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$PATH"
	export PATH
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
	rm -f "$CALLS"
}

# field <check-id> <field> - one value from health.json
field() {
	jq -r --arg id "$1" ".checks[] | select(.id == \$id) | .$2" "$HEALTH"
}

stats_line() {
	echo "{\"timestamp\":\"t\",\"event_type\":\"stats\",\"stats\":{\"capture\":{\"kernel_packets\":$1,\"kernel_drops\":$2}}}" >>"$EVE"
}

@test "criterion 2: a stopped suricata is crit in one run, a running one is ok" {
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ "$(field suricata.process status)" = "ok" ]

	FAKE_STOPPED="suricata.service" run "$WATCH"
	[ "$(field suricata.process status)" = "crit" ]
	[ "$(field suricata.process value)" = "inactive" ]
	FAKE_FAILED="suricata.service" run "$WATCH"
	[ "$(field suricata.process status)" = "crit" ]
}

@test "criterion 1: a component that is not installed gets na" {
	FAKE_UNITS="suricata.service" run "$WATCH"
	[ "$(field evebox.process status)" = "na" ]
	[ "$(field evebox.port status)" = "na" ]
	[ "$(jq -r '.overall' "$HEALTH")" = "ok" ]
}

@test "criterion 1: ports are warn for the first two missing runs, crit from the third" {
	FAKE_LISTEN="3000 6379 9800" run "$WATCH"
	[ "$(field evebox.port status)" = "warn" ]
	FAKE_LISTEN="3000 6379 9800" run "$WATCH"
	[ "$(field evebox.port status)" = "warn" ]
	FAKE_LISTEN="3000 6379 9800" run "$WATCH"
	[ "$(field evebox.port status)" = "crit" ]
	# Listening again resets the count.
	run "$WATCH"
	[ "$(field evebox.port status)" = "ok" ]
	FAKE_LISTEN="3000 6379 9800" run "$WATCH"
	[ "$(field evebox.port status)" = "warn" ]
}

@test "criterion 1 and 3: eve age exactly at WATCH_EVE_STALE_SEC is crit, one second less is ok" {
	touch -d "@$((NOW - 299))" "$EVE"
	run "$WATCH"
	[ "$(field suricata.eve_fresh status)" = "ok" ]
	touch -d "@$((NOW - 300))" "$EVE"
	run "$WATCH"
	[ "$(field suricata.eve_fresh status)" = "crit" ]
	rm -f "$EVE"
	run "$WATCH"
	[ "$(field suricata.eve_fresh status)" = "warn" ]
}

@test "criterion 3: EVE_FILE=no or no stats in EVE_TYPES gives na, and overall ignores it" {
	touch -d "@$((NOW - 9999))" "$EVE"
	echo 'EVE_FILE=no' >"$CONF_FILE"
	run "$WATCH"
	[ "$(field suricata.eve_fresh status)" = "na" ]
	[ "$(field suricata.drop_rate status)" = "na" ]
	[ "$(jq -r '.overall' "$HEALTH")" = "ok" ]

	echo 'EVE_TYPES=alert,dns' >"$CONF_FILE"
	run "$WATCH"
	[ "$(field suricata.eve_fresh status)" = "na" ]
	[ "$(field suricata.drop_rate status)" = "na" ]
}

@test "criterion 1: drop rate edges, WARN 1 and CRIT 5" {
	for case in "99 ok" "100 warn" "499 warn" "500 crit"; do
		set -- $case
		echo '{"event_type":"stats"}' >"$EVE"
		stats_line 1000 0
		stats_line 11000 "$1"
		touch -d "@$((NOW - 10))" "$EVE"
		run "$WATCH"
		[ "$(field suricata.drop_rate status)" = "$2" ]
	done
	[ "$(field suricata.drop_rate value)" = "5.00" ]
	[ "$(jq -r '.overall' "$HEALTH")" = "crit" ]
}

@test "criterion 4: a counter reset is not a false drop rate" {
	echo '{"event_type":"stats"}' >"$EVE"
	stats_line 5000000 40000
	stats_line 1200 10
	touch -d "@$((NOW - 10))" "$EVE"
	run "$WATCH"
	[ "$(field suricata.drop_rate status)" = "ok" ]
	[[ "$(field suricata.drop_rate detail)" == *"сброшены"* ]]

	# One stats event is not enough to compute anything.
	echo '{"event_type":"stats"}' >"$EVE"
	stats_line 1000 0
	touch -d "@$((NOW - 10))" "$EVE"
	run "$WATCH"
	[ "$(field suricata.drop_rate status)" = "na" ]
}

@test "criterion 5: disk.free takes the worst of several paths and names it" {
	FAKE_DF_SURICATA=6000 FAKE_DF_EVEBOX=1400 run "$WATCH"
	[ "$(field disk.free status)" = "warn" ]
	[[ "$(field disk.free detail)" == *"/var/lib/evebox"* ]]
	[ "$(field disk.free value)" = "14.00" ]

	FAKE_DF_SURICATA=400 FAKE_DF_EVEBOX=9000 run "$WATCH"
	[ "$(field disk.free status)" = "crit" ]
	[[ "$(field disk.free detail)" == *"/var/log/suricata"* ]]
}

@test "criterion 1 and 5: disk edges, WARN 15 and CRIT 5 percent free" {
	for case in "1501 ok" "1500 warn" "501 warn" "500 crit"; do
		set -- $case
		FAKE_DF_SURICATA="$1" run "$WATCH"
		[ "$(field disk.free status)" = "$2" ]
	done
	# EveBox on elasticsearch has no local data dir to watch.
	echo 'EVEBOX_DB=elasticsearch' >"$CONF_FILE"
	echo 'EVEBOX_ES_URL=http://127.0.0.1:9200' >>"$CONF_FILE"
	FAKE_DF_EVEBOX=100 FAKE_DF_SURICATA=9000 run "$WATCH"
	[ "$(field disk.free status)" = "ok" ]
}

@test "criterion 1: rules age edges, WARN 10 and CRIT 30 days" {
	day=86400
	for case in "$((10 * day - 1)) ok" "$((10 * day)) warn" "$((30 * day - 1)) warn" "$((30 * day)) crit"; do
		set -- $case
		touch -d "@$((NOW - $1))" "$RULES"
		run "$WATCH"
		[ "$(field rules.age status)" = "$2" ]
	done
	echo 'RULES_UPDATE=off' >"$CONF_FILE"
	run "$WATCH"
	[ "$(field rules.age status)" = "na" ]
}

@test "criterion 6: health.json is valid, atomic, and since moves only when the status changes" {
	run "$WATCH"
	[ "$status" -eq 0 ]
	jq -e '.ts and .overall and (.checks | length > 0)' "$HEALTH" >/dev/null
	[ "$(field suricata.process since)" = "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" ]
	[ -z "$(find "$(dirname "$HEALTH")" -name '.tmp.*' -o -name 'tmp.*')" ]
	for f in id status value detail since; do
		[ "$(jq "[.checks[] | has(\"$f\")] | all" "$HEALTH")" = "true" ]
	done

	DPISTACK_NOW=$((NOW + 60)) run "$WATCH"
	[ "$(jq -r '.ts' "$HEALTH")" = "$(date -u -d "@$((NOW + 60))" +%Y-%m-%dT%H:%M:%SZ)" ]
	[ "$(field suricata.process since)" = "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)" ]

	FAKE_STOPPED="suricata.service" DPISTACK_NOW=$((NOW + 120)) run "$WATCH"
	[ "$(field suricata.process since)" = "$(date -u -d "@$((NOW + 120))" +%Y-%m-%dT%H:%M:%SZ)" ]
}

@test "criterion 6: a status change writes one events.jsonl line, a steady status none" {
	run "$WATCH"
	[ ! -s "$EVENTS" ]
	FAKE_STOPPED="suricata.service" DPISTACK_NOW=$((NOW + 60)) run "$WATCH"
	FAKE_STOPPED="suricata.service" DPISTACK_NOW=$((NOW + 120)) run "$WATCH"
	[ "$(grep -c '"check":"suricata.process"' "$EVENTS")" -eq 1 ]
	line="$(grep '"check":"suricata.process"' "$EVENTS")"
	[ "$(echo "$line" | jq -r '.from')" = "ok" ]
	[ "$(echo "$line" | jq -r '.to')" = "crit" ]
}

@test "criterion 7: WATCH_AUTORESTART=yes restarts a failed component at most 3 times an hour" {
	echo 'WATCH_AUTORESTART=yes' >"$CONF_FILE"
	for i in 0 1 2 3 4; do
		FAKE_FAILED="suricata.service" DPISTACK_NOW=$((NOW + i * 60)) run "$WATCH"
	done
	[ "$(grep -c '^systemctl restart suricata.service$' "$CALLS")" -eq 3 ]

	# An hour after the first restart the window frees up again.
	FAKE_FAILED="suricata.service" DPISTACK_NOW=$((NOW + 3601)) run "$WATCH"
	[ "$(grep -c '^systemctl restart suricata.service$' "$CALLS")" -eq 4 ]
}

@test "criterion 7: with WATCH_AUTORESTART=no nothing is restarted" {
	FAKE_FAILED="suricata.service" run "$WATCH"
	FAKE_FAILED="suricata.service" DPISTACK_NOW=$((NOW + 60)) run "$WATCH"
	! grep -q '^systemctl restart' "$CALLS"
}

@test "criterion 8: ctl health runs the watchdog once and prints the same JSON" {
	run "$CTL" health --json
	[ "$status" -eq 0 ]
	[ "$output" = "$(cat "$HEALTH")" ]
	echo "$output" | jq -e '.checks | length > 0' >/dev/null

	run "$CTL" health
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata.process"* ]]
	run "$CTL" health --bogus
	[ "$status" -eq 2 ]
}

@test "two overlapping runs do not both write: the second exits quietly" {
	exec 9>"$DPISTACK_ROOT/var/lib/dpistack/.watch.lock" 2>/dev/null || {
		mkdir -p "$DPISTACK_ROOT/var/lib/dpistack"
		exec 9>"$DPISTACK_ROOT/var/lib/dpistack/.watch.lock"
	}
	flock -n 9
	run "$WATCH"
	[ "$status" -eq 0 ]
	[ ! -e "$HEALTH" ]
	exec 9>&-
}
