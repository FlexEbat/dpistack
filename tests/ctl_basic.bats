#!/usr/bin/env bats
# Covers slice 10 criteria 1-4 (status, start|stop|restart, logs,
# argument checks). Criterion 5 (sudo as the dpistack user) needs a real
# host and is checked by hand.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/bin/dpistack-ctl"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	FAKE_BIN="$(mktemp -d)"
	CALLS="$(mktemp)"
	export CALLS
	# Units that exist on the fake host; the rest report not-found.
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
	echo active
	;;
is-enabled) exit 0 ;;
*) echo "systemctl $*" >>"$CALLS" ;;
esac
FAKE
	cat >"$FAKE_BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
echo "journalctl $*" >>"$CALLS"
if [[ " $* " == *" --follow "* ]]; then
	while true; do echo "line"; sleep 0.05; done
fi
FAKE
	cat >"$FAKE_BIN/suricata" <<'FAKE'
#!/usr/bin/env bash
echo "This is Suricata version 8.0.1 RELEASE"
FAKE
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$PATH"
	export PATH
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN" "$CALLS"
}

@test "criterion 1: status --json is valid JSON with every installed component" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/usr/lib/suricata"
	printf 'METRICS_BACKEND=none\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	: >"$DPISTACK_ROOT/usr/lib/suricata/ndpi.so"
	FAKE_FAILED="ntopng.service"
	export FAKE_FAILED

	run "$CTL" status --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e . >/dev/null
	[ "$(echo "$output" | jq -r '.ndpi_plugin')" = "loaded" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="suricata") | .state')" = "active" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="suricata") | .version')" = "8.0.1" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="ntopng") | .state')" = "failed" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="redis") | .state')" = "active" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="watch") | .state')" = "absent" ]
	# Backends outside METRICS_BACKEND are not listed.
	[ "$(echo "$output" | jq -r '[.components[] | select(.id=="victoriametrics" or .id=="prometheus")] | length')" = "0" ]
	for f in id runtime state enabled version; do
		[ "$(echo "$output" | jq "[.components[] | has(\"$f\")] | all")" = "true" ]
	done
}

@test "criterion 1: ndpi_plugin is absent without ndpi.so and a selected backend is listed" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'METRICS_BACKEND=prometheus\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"

	run "$CTL" status --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.ndpi_plugin')" = "absent" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="prometheus") | .state')" = "absent" ]
}

@test "criterion 2: restart goes through systemctl for the component's unit" {
	run "$CTL" restart suricata
	[ "$status" -eq 0 ]
	grep -qx "systemctl restart suricata.service" "$CALLS"

	run "$CTL" stop redis
	[ "$status" -eq 0 ]
	grep -qx "systemctl stop redis-server.service" "$CALLS"
}

@test "criterion 2: an id outside the list gives 5, an absent component gives 4" {
	run "$CTL" start nosuchthing
	[ "$status" -eq 5 ]
	run "$CTL" start watch
	[ "$status" -eq 4 ]
	run "$CTL" restart victoriametrics
	[ "$status" -eq 4 ]
	[ ! -s "$CALLS" ]
}

@test "criterion 3: logs -n 5000 gives 2 and journalctl is not called" {
	run "$CTL" logs suricata -n 5000
	[ "$status" -eq 2 ]
	run "$CTL" logs suricata -n abc
	[ "$status" -eq 2 ]
	[ ! -s "$CALLS" ]
}

@test "criterion 3: logs -n 1000 passes the limit to journalctl" {
	run "$CTL" logs suricata -n 1000
	[ "$status" -eq 0 ]
	grep -q -- "-u suricata.service -n 1000" "$CALLS"
}

@test "criterion 3: logs --follow ends when the reader closes the stream" {
	run timeout 10 bash -c "'$CTL' logs suricata --follow | head -n 1"
	[ "$status" -eq 0 ]
	[ "$output" = "line" ]
}

@test "criterion 4: shell metacharacters give 5 and nothing runs" {
	marker="$DPISTACK_ROOT/pwned"
	run "$CTL" restart "suricata;touch $marker"
	[ "$status" -eq 5 ]
	run "$CTL" restart 'suricata$(touch '"$marker"')'
	[ "$status" -eq 5 ]
	run "$CTL" logs 'suricata`touch '"$marker"'`'
	[ "$status" -eq 5 ]
	run "$CTL" status '--json|cat'
	[ "$status" -eq 5 ]
	[ ! -e "$marker" ]
	[ ! -s "$CALLS" ]
}

@test "version prints the set version" {
	run "$CTL" version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "commands owned by later slices exit 4, unknown commands exit 2" {
	run "$CTL" config-read suricata.yaml
	[ "$status" -eq 4 ]
	run "$CTL" frobnicate
	[ "$status" -eq 2 ]
}
