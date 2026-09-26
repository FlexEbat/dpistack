#!/usr/bin/env bats
# Covers slice 1 criteria 2, 5, 9.

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
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

@test "install --dry-run -y passes every step and changes nothing" {
	run bash "$REPO_DIR/install.sh" install --dry-run -y
	[ "$status" -eq 0 ]
	for step in preflight selfinstall ndpi suricata rules redis ntopng evebox metrics access panel watch verify; do
		[[ "$output" == *"$step ... без изменений"* ]]
	done
	[ ! -e "$CONF_FILE" ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack/state" ]
}

@test "interactive answers are saved, and a repeat -y run gives the same config" {
	input_file="$(mktemp)"
	# 11 basic questions in schema order: SURICATA_RUNTIME, EVEBOX_RUNTIME,
	# NTOPNG_RUNTIME, SURICATA_SOURCE, NDPI_ENABLE, PIN_VERSIONS, IFACES,
	# EVE_TYPES, ACCESS_MODE, METRICS_BACKEND, ALERT_CHANNELS.
	printf '\n\n\n\n\nyes\nenp7s0\n\n\n\n\n' >"$input_file"
	run env DPISTACK_INPUT="$input_file" bash "$REPO_DIR/install.sh" install
	[ "$status" -eq 0 ]
	[ -f "$CONF_FILE" ]
	grep -q '^IFACES=enp7s0$' "$CONF_FILE"
	grep -q '^PIN_VERSIONS=yes$' "$CONF_FILE"

	first_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run bash "$REPO_DIR/install.sh" install -y
	[ "$status" -eq 0 ]
	second_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$first_sum" = "$second_sum" ]
	rm -f "$input_file"
}

@test "reconfigure --dry-run shows the key diff and affected steps, changes nothing" {
	run bash "$REPO_DIR/install.sh" install -y
	[ "$status" -eq 0 ]
	before_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run bash "$REPO_DIR/install.sh" reconfigure --dry-run -y --set IFACES=eth7
	[ "$status" -eq 0 ]
	[[ "$output" == *"IFACES"* ]]
	[[ "$output" == *"eth7"* ]]
	[[ "$output" == *"suricata"* ]]

	after_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
}

@test "reconfigure with no changes reports no changes" {
	run bash "$REPO_DIR/install.sh" install -y
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" reconfigure --dry-run -y
	[ "$status" -eq 0 ]
	[[ "$output" == *"изменений нет"* ]]
}
