#!/usr/bin/env bats
# Covers slice 5 criteria 2 and 4 (per tech.md's own test scope).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	cat >"$DPISTACK_ROOT/etc/os-release" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

load_ntopng() {
	bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		config_reset
		config_load_defaults
		'"$1"'
		source "'"$REPO_DIR"'/lib/step_ntopng.sh"
		'"$2"'
	'
}

@test "criterion 2: NTOPNG_IFACES follows IFACES by default" {
	run load_ntopng 'CONF[IFACES]="eth3"' 'ntopng_effective_ifaces'
	[ "$status" -eq 0 ]
	[ "$output" = "eth3" ]
}

@test "criterion 2: an explicit NTOPNG_IFACES overrides IFACES" {
	run load_ntopng 'CONF[IFACES]="eth3"; CONF[NTOPNG_IFACES]="eth9"' 'ntopng_effective_ifaces'
	[ "$status" -eq 0 ]
	[ "$output" = "eth9" ]
}

@test "criterion 2: rendered conf uses the effective interface" {
	run load_ntopng 'CONF[IFACES]="eth3"' 'ntopng_render_interfaces_block'
	[ "$status" -eq 0 ]
	[[ "$output" == *"-i=eth3"* ]]
}

@test "criterion 4: a second install run reports no changes for ntopng" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]

	run bash "$REPO_DIR/install.sh" status \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"ntopng: в порядке"* ]]
}
