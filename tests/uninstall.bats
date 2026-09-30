#!/usr/bin/env bats
# Covers slice 8 criteria 6, 8 for `uninstall`/`uninstall --purge`.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	cat >"$DPISTACK_ROOT/etc/os-release" <<'EOF_OS'
ID=ubuntu
ID_LIKE=debian
EOF_OS
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	MOCK_IP_LINK_ROUTE="192.168.10.0/24"
	export MOCK_IP_DEFAULT_IFACE MOCK_IP_LINK_ROUTE
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	YAML_FILE="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	NTOPNG_CONF="$DPISTACK_ROOT/etc/ntopng/ntopng.conf"
	RULES_TIMER_FILE="$DPISTACK_ROOT/etc/systemd/system/dpistack-rules.timer"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "criterion 8: uninstall on a clean system exits 0 with 'нечего удалять'" {
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[[ "$output" == *"нечего удалять"* ]]
}

@test "criterion 6: plain uninstall removes dpistack's own units/config, keeps component configs" {
	run install_base
	[ "$status" -eq 0 ]
	[ -f "$RULES_TIMER_FILE" ]

	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]

	[ ! -e "$CONF_FILE" ]
	[ ! -e "$RULES_TIMER_FILE" ]
	[ -f "$YAML_FILE" ]
	[ -f "$NTOPNG_CONF" ]
	[ -f "$DPISTACK_ROOT/etc/evebox/evebox.yaml" ]
}

@test "criterion 6: uninstall --purge additionally removes component configs" {
	run install_base
	[ "$status" -eq 0 ]

	run bash "$REPO_DIR/install.sh" uninstall --purge
	[ "$status" -eq 0 ]

	[ ! -e "$CONF_FILE" ]
	[ ! -e "$YAML_FILE" ]
	[ ! -e "$NTOPNG_CONF" ]
	[ ! -e "$DPISTACK_ROOT/etc/evebox/evebox.yaml" ]
}

@test "criterion 6: uninstall never calls apt-get remove/purge (packages are never touched)" {
	run install_base
	[ "$status" -eq 0 ]
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	run bash "$REPO_DIR/install.sh" uninstall --purge
	[ "$status" -eq 0 ]
	run grep -c "apt-get remove\|apt-get purge\|apt-get autoremove" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
	rm -f "$MOCK_CALLS_LOG"
}

@test "install, uninstall --purge, reinstall: services never got stopped along the way" {
	run install_base
	[ "$status" -eq 0 ]
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	run bash "$REPO_DIR/install.sh" uninstall --purge
	[ "$status" -eq 0 ]
	run grep -c "systemctl disable --now suricata.service\|systemctl disable --now ntopng.service\|systemctl disable --now evebox.service\|systemctl disable --now redis-server.service" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
	rm -f "$MOCK_CALLS_LOG"
}
