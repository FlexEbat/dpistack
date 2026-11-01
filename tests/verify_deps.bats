#!/usr/bin/env bats
# v0.29.1: TEST_BT_LIVE=yes needs tcpreplay; the installer brings it instead of
# failing the test for a missing tool (real Debian 13 install).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES=enp2s0
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	command -v tcpreplay >/dev/null 2>&1 && skip "the host has tcpreplay"
	return 0
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

@test "TEST_BT_LIVE=yes without tcpreplay installs it before the tests" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_BT_LIVE=yes
	[ "$status" -eq 0 ]
	grep -q "^apt-get install -y tcpreplay" "$MOCK_CALLS_LOG"
}

@test "TEST_BT_LIVE=no never touches tcpreplay" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_BT_LIVE=no
	[ "$status" -eq 0 ]
	run grep -c "tcpreplay" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
}
