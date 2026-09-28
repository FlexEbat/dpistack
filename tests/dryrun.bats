#!/usr/bin/env bats
# Covers slice 1 criteria 2, 5, 9. SURICATA_SOURCE=oisf/NDPI_ENABLE=no
# are set explicitly because slice 2 marks their defaults
# (source/yes) as "пока не поддерживается" until slice 4.

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
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

@test "install --dry-run -y passes every step and changes nothing" {
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	for step in selfinstall ndpi evebox metrics access panel watch verify; do
		[[ "$output" == *"$step ... без изменений"* ]]
	done
	# suricata, rules, redis, ntopng have real check/apply logic by now
	# (slices 2-5): a fresh root has nothing installed yet, so they
	# correctly plan work instead of claiming "без изменений" - dry-run's
	# job is to not touch disk, not to pretend there is nothing to do.
	[[ "$output" == *"suricata ... нужно применить"* ]]
	[[ "$output" == *"rules ... нужно применить"* ]]
	[[ "$output" == *"redis ... нужно применить"* ]]
	[[ "$output" == *"ntopng ... нужно применить"* ]]
	[ ! -e "$CONF_FILE" ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack/state" ]
	[ ! -e "$DPISTACK_ROOT/etc/suricata/suricata.yaml" ]
}

@test "interactive answers are saved, and a repeat -y run gives the same config" {
	input_file="$(mktemp)"
	# 11 basic questions in schema order: SURICATA_RUNTIME, EVEBOX_RUNTIME,
	# NTOPNG_RUNTIME, SURICATA_SOURCE, NDPI_ENABLE, PIN_VERSIONS, IFACES,
	# EVE_TYPES, ACCESS_MODE, METRICS_BACKEND, ALERT_CHANNELS.
	printf '\n\n\noisf\nno\nyes\nenp7s0\n\n\n\n\n' >"$input_file"
	MOCK_IP_EXISTING_IFACES="enp7s0"
	run env DPISTACK_INPUT="$input_file" MOCK_IP_EXISTING_IFACES="enp7s0" \
		bash "$REPO_DIR/install.sh" install
	[ "$status" -eq 0 ]
	[ -f "$CONF_FILE" ]
	grep -q '^IFACES=enp7s0$' "$CONF_FILE"
	grep -q '^PIN_VERSIONS=yes$' "$CONF_FILE"

	first_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run env MOCK_IP_EXISTING_IFACES="enp7s0" bash "$REPO_DIR/install.sh" install -y
	[ "$status" -eq 0 ]
	second_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$first_sum" = "$second_sum" ]
	rm -f "$input_file"
}

@test "reconfigure --dry-run shows the key diff and affected steps, changes nothing" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
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
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" reconfigure --dry-run -y
	[ "$status" -eq 0 ]
	[[ "$output" == *"изменений нет"* ]]
}
