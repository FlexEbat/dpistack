#!/usr/bin/env bats
# R144-R146: how eve.json is rotated, who can read it, and where the command
# socket is. Each of these was wrong while the tests only looked at the
# rendered text; the facts they now pin down were checked against a real
# Suricata 7.0.3 and a real logrotate (tech.md 18.22).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	YAML="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	LOGDIR="$DPISTACK_ROOT/var/log/suricata"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "R144: logrotate keeps the owner and mode of eve.json, it does not make it root-only" {
	run install_base
	[ "$status" -eq 0 ]
	f="$(ls "$DPISTACK_ROOT"/etc/logrotate.d/* | head -1)"
	grep -qx '    create' "$f"
	if grep -q 'create 0640 root root' "$f"; then false; fi
}

@test "R146: logrotate reopens eve.json through the socket Suricata really creates" {
	run install_base
	[ "$status" -eq 0 ]
	f="$(ls "$DPISTACK_ROOT"/etc/logrotate.d/* | head -1)"
	sock="$DPISTACK_ROOT/run/suricata-command.socket"
	grep -q -- "suricatasc -c reopen-log-files $sock 2>/dev/null || true" "$f"
	# the socket of the rendered suricata.yaml is the one logrotate and
	# dpistack reload talk to
	grep -qx "  filename: $sock" "$YAML"
	grep -q 'filemode: 0640' "$YAML"
}

@test "R146: in a container the socket is in the mounted run directory and logrotate reaches it through compose" {
	run install_base --set SURICATA_RUNTIME=docker
	[ "$status" -eq 0 ]
	grep -qx '  filename: /var/run/suricata/suricata-command.socket' "$YAML"
	f="$(ls "$DPISTACK_ROOT"/etc/logrotate.d/* | head -1)"
	grep -q 'exec -T suricata suricatasc -c reopen-log-files /var/run/suricata/suricata-command.socket' "$f"
	# the host has no suricatasc to call
	if grep -q '/usr/bin/suricatasc' "$f"; then false; fi
}

@test "R145: a host without the group suricata gets it, and the root-owned log directory goes to it" {
	MOCK_GETENT_MISSING="suricata" DPISTACK_TEST_LOG_OWNER=root run install_base
	[ "$status" -eq 0 ]
	grep -qx 'groupadd --system suricata' "$MOCK_CALLS_LOG"
	grep -qx "chgrp suricata $LOGDIR" "$MOCK_CALLS_LOG"
	# setgid, so eve.json born after a logrotate keeps the group
	[ "$(stat -c %a "$LOGDIR")" = "2750" ]
}

@test "R145: a log directory that belongs to a user (the RPM layout) is not taken over" {
	DPISTACK_TEST_LOG_OWNER=suricata run install_base
	[ "$status" -eq 0 ]
	if grep -q "^chgrp suricata $LOGDIR\$" "$MOCK_CALLS_LOG"; then false; fi
	if grep -q '^groupadd' "$MOCK_CALLS_LOG"; then false; fi
}
