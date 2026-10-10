#!/usr/bin/env bats
# The watch step: binary, service and timer units, idempotency.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	TIMER="$DPISTACK_ROOT/etc/systemd/system/dpistack-watch.timer"
	SERVICE="$DPISTACK_ROOT/etc/systemd/system/dpistack-watch.service"
	BIN="$DPISTACK_ROOT/usr/local/sbin/dpistack-watch"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no "$@"
}

@test "install puts the binary and both units in place and starts the timer" {
	run install_base
	[ "$status" -eq 0 ]
	cmp "$REPO_DIR/bin/dpistack-watch" "$BIN"
	[ -x "$BIN" ]
	grep -qx "OnUnitActiveSec=60s" "$TIMER"
	grep -qx "ExecStart=$BIN" "$SERVICE"
	grep -q "^ConditionPathExists=$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/paths.sh$" "$SERVICE"
	grep -q "^systemctl enable --now dpistack-watch.timer" "$MOCK_CALLS_LOG"
}

@test "second run reports watch unchanged and does not touch the timer again" {
	run install_base
	[ "$status" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[[ "$output" == *"watch: в порядке"* ]]
	run install_base
	[ "$status" -eq 0 ]
	! grep -q "dpistack-watch.timer" "$MOCK_CALLS_LOG"
}

@test "a changed WATCH_INTERVAL_SEC re-renders the timer through reconfigure" {
	run install_base
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" reconfigure -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set WATCH_INTERVAL_SEC=120
	[ "$status" -eq 0 ]
	grep -qx "OnUnitActiveSec=120s" "$TIMER"
	grep -q "^systemctl restart dpistack-watch.timer" "$MOCK_CALLS_LOG"
}

@test "WATCH_ENABLE=no installs no units and no timer" {
	run install_base --set WATCH_ENABLE=no
	[ "$status" -eq 0 ]
	[ ! -e "$TIMER" ]
	[ ! -e "$SERVICE" ]
	! grep -q "enable --now dpistack-watch.timer" "$MOCK_CALLS_LOG"
}
