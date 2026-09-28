#!/usr/bin/env bats
# Covers slice 2 criteria 2, 3, 5, 6, 7 (on stubs/mocks, per tech.md's
# own note for this slice's test scope).

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
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

load_step() {
	# Sources just enough to call suricata_render_* directly, the way
	# criteria 2 and 3 are about render shape, not a full install.
	bash -c '
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/render.sh"
		config_reset
		config_load_defaults
		'"$1"'
		source "'"$REPO_DIR"'/lib/step_suricata.sh"
		'"$2"'
	'
}

@test "criterion 2: two interfaces give two af-packet blocks with different cluster-id" {
	run load_step 'CONF[IFACES]="eth1,eth2"' 'suricata_render_af_packet_block'
	[ "$status" -eq 0 ]
	[[ "$output" == *"interface: eth1"* ]]
	[[ "$output" == *"interface: eth2"* ]]
	[[ "$output" == *"cluster-id: 99"* ]]
	[[ "$output" == *"cluster-id: 100"* ]]
}

@test "criterion 3: EVE_TYPES=alert,dns renders only those two types" {
	run load_step 'CONF[EVE_TYPES]="alert,dns"' 'suricata_render_eve_types_block'
	[ "$status" -eq 0 ]
	[[ "$output" == *"- alert"* ]]
	[[ "$output" == *"- dns"* ]]
	[[ "$output" != *"- stats"* ]]
	[[ "$output" != *"- flow"* ]]
}

@test "criterion 3: stats is present when listed in EVE_TYPES" {
	run load_step 'CONF[EVE_TYPES]="alert,stats"' 'suricata_render_eve_types_block'
	[ "$status" -eq 0 ]
	[[ "$output" == *"- stats"* ]]
}

@test "criterion 5: nonexistent interface stops preflight with code 3, before any package install" {
	MOCK_IP_EXISTING_IFACES="eth0" \
		run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set IFACES=doesnotexist0
	[ "$status" -eq 3 ]
	[[ "$output" == *"doesnotexist0"* ]]
	run grep -c "apt-get install" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
}

@test "criterion 6: second run reports no changes; manually edited file needs --force" {
	MOCK_IP_EXISTING_IFACES="eth0"
	export MOCK_IP_EXISTING_IFACES
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth0
	[ "$status" -eq 0 ]

	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth0
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata: в порядке"* ]]

	# Hand-edit the rendered file; a plain re-run must leave it alone.
	yaml_path="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	echo "# hand edit" >>"$yaml_path"
	before_sum=$(sha256sum "$yaml_path" | cut -d' ' -f1)

	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth0
	[ "$status" -eq 0 ]
	after_sum=$(sha256sum "$yaml_path" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
	[[ "$output" == *"изменён вручную"* ]]

	run bash "$REPO_DIR/install.sh" install -y --force \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth0
	[ "$status" -eq 0 ]
	forced_sum=$(sha256sum "$yaml_path" | cut -d' ' -f1)
	[ "$before_sum" != "$forced_sum" ]
	backups_dir="$DPISTACK_ROOT/var/lib/dpistack/backups"
	[ -n "$(ls -A "$backups_dir" 2>/dev/null)" ]
}

@test "criterion 7: PIN_VERSIONS=yes pins the package" {
	MOCK_IP_EXISTING_IFACES="eth0" \
		run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set IFACES=eth0 --set PIN_VERSIONS=yes
	[ "$status" -eq 0 ]
	run grep -c "apt-mark $(printf '%s' 'hold suricata')" "$MOCK_CALLS_LOG"
	[ "$output" = "1" ]
}
