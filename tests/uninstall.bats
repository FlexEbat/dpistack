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

@test "criterion 8: uninstall on a clean system exits 0 with 'nothing to remove'" {
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to remove"* ]]
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

@test "uninstall --purge takes the docker project down, removes dpistack's own leftovers and nothing foreign" {
	run install_base --set EVEBOX_RUNTIME=docker
	[ "$status" -eq 0 ]
	mkdir -p "$DPISTACK_ROOT/opt/dpistack/compose" "$DPISTACK_ROOT/etc/dpistack/grafana-provisioning" \
		"$DPISTACK_ROOT/var/log/dpistack" "$DPISTACK_ROOT/var/lib/evebox" "$DPISTACK_ROOT/usr/local/src/dpistack-ndpi"
	echo x >"$DPISTACK_ROOT/opt/dpistack/compose/compose.yaml"
	echo x >"$DPISTACK_ROOT/etc/dpistack/grafana.ini"
	echo x >"$DPISTACK_ROOT/etc/dpistack/metrics.token"
	echo keep >"$DPISTACK_ROOT/etc/other.conf"
	mkdir -p "$DPISTACK_ROOT/opt/foreign"
	echo keep >"$DPISTACK_ROOT/opt/foreign/file"
	export MOCK_CALLS_LOG="$BATS_TEST_TMPDIR/calls.log"
	export MOCK_DOCKER_IMAGES=$'dpistack-panel:abc123def456\nnginx:latest\n'
	run bash "$REPO_DIR/install.sh" uninstall --purge
	[ "$status" -eq 0 ]
	grep -q "^docker compose -p .* down --remove-orphans" "$MOCK_CALLS_LOG"
	grep -q "^docker image rm dpistack-panel:abc123def456" "$MOCK_CALLS_LOG"
	# no blanket cleanup, no foreign image
	run grep -E "prune|image rm nginx|system |volume rm|network rm|^docker rm " "$MOCK_CALLS_LOG"
	[ "$status" -ne 0 ]
	[ ! -e "$DPISTACK_ROOT/opt/dpistack" ]
	[ ! -e "$DPISTACK_ROOT/etc/dpistack" ]
	[ ! -e "$DPISTACK_ROOT/var/log/dpistack" ]
	[ ! -e "$DPISTACK_ROOT/var/lib/evebox" ]
	[ ! -e "$DPISTACK_ROOT/usr/local/src/dpistack-ndpi" ]
	[ -f "$DPISTACK_ROOT/etc/other.conf" ]
	[ -f "$DPISTACK_ROOT/opt/foreign/file" ]
}

@test "a plain uninstall keeps the data directories and the logs" {
	run install_base
	[ "$status" -eq 0 ]
	mkdir -p "$DPISTACK_ROOT/var/lib/evebox" "$DPISTACK_ROOT/var/log/dpistack"
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ -d "$DPISTACK_ROOT/var/lib/evebox" ]
	[ -d "$DPISTACK_ROOT/var/log/dpistack" ]
}

@test "the installation menu offers Uninstall and removes only after the word remove" {
	run install_base
	[ "$status" -eq 0 ]
	f="$BATS_TEST_TMPDIR/in"
	printf '4\nremove\n2\n' >"$f"
	DPISTACK_INPUT="$f" run bash "$REPO_DIR/install.sh" install
	[ "$status" -eq 0 ]
	[[ "$output" == *"4) Uninstall"* ]]
	[ ! -e "$CONF_FILE" ]
	printf '4\nnope\n' >"$f"
	run install_base
	DPISTACK_INPUT="$f" run bash "$REPO_DIR/install.sh" install
	[[ "$output" == *"cancelled"* ]]
	[ -f "$CONF_FILE" ]
}
