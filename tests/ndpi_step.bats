#!/usr/bin/env bats
# Covers slice 4 criteria 3 and 6 (per tech.md's own test scope for
# this slice). git/autogen.sh/configure/make are real, relative-path
# invocations inside a cloned tree, not PATH-resolved commands, so
# they can't be intercepted the way apt-get/systemctl are; criterion 6
# (idempotency) is exercised directly against step_ndpi_check's state
# logic instead of a full build.

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

@test "criterion 3: NDPI_ENABLE=yes without SURICATA_SOURCE=source and no ndpi.so exits 2" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=yes
	[ "$status" -eq 2 ]
	[[ "$output" == *"SURICATA_SOURCE=source"* ]]
}

@test "criterion 3: NDPI_ENABLE=yes with SURICATA_SOURCE=oisf passes once ndpi.so exists" {
	mkdir -p "$(dirname "$DPISTACK_ROOT/usr/lib/suricata/ndpi.so")"
	touch "$DPISTACK_ROOT/usr/lib/suricata/ndpi.so"
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=yes
	[ "$status" -eq 0 ]
}

@test "criterion 6: a second check does not report work needed for the same already-built version" {
	mkdir -p "$DPISTACK_ROOT/usr/local/lib"
	touch "$DPISTACK_ROOT/usr/local/lib/libndpi.so"

	run bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/state.sh"
		config_reset
		config_load_defaults
		CONF[NDPI_ENABLE]="yes"
		CONF[NDPI_SOURCE]="source"
		CONF[NDPI_VERSION]="v4.14"
		source "'"$REPO_DIR"'/lib/step_ndpi.sh"
		state_write_value "ndpi.built_ref" "v4.14"
		step_ndpi_check && echo "ALREADY_DONE"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALREADY_DONE"* ]]
}

@test "criterion 6: a different NDPI_VERSION than what was built is reported as work needed" {
	mkdir -p "$DPISTACK_ROOT/usr/local/lib"
	touch "$DPISTACK_ROOT/usr/local/lib/libndpi.so"

	run bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/state.sh"
		config_reset
		config_load_defaults
		CONF[NDPI_ENABLE]="yes"
		CONF[NDPI_SOURCE]="source"
		CONF[NDPI_VERSION]="v4.14"
		source "'"$REPO_DIR"'/lib/step_ndpi.sh"
		state_write_value "ndpi.built_ref" "v4.12"
		step_ndpi_check && echo "ALREADY_DONE" || echo "NEEDS_BUILD"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"NEEDS_BUILD"* ]]
}
