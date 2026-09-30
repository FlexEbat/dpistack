#!/usr/bin/env bats
# Covers slice 8 criteria 1-5, 9 for `reconfigure` and `upgrade`.

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
	MOCK_IP_EXISTING_IFACES="enp2s0,eth7"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	YAML_FILE="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	NTOPNG_CONF="$DPISTACK_ROOT/etc/ntopng/ntopng.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "criterion 1: reconfigure without dpistack.conf exits 2" {
	run bash "$REPO_DIR/install.sh" reconfigure -y
	[ "$status" -eq 2 ]
}

@test "criterion 1: reconfigure with no changes prints 'изменений нет' and exits 0" {
	run install_base
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" reconfigure -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"изменений нет"* ]]
}

@test "criterion 2: changing IFACES redraws suricata.yaml and ntopng.conf, restarts both, leaves others alone" {
	run install_base
	[ "$status" -eq 0 ]
	before_evebox=$(sha256sum "$DPISTACK_ROOT/etc/evebox/evebox.yaml" | cut -d' ' -f1)
	: >"$MOCK_CALLS_LOG"

	run bash "$REPO_DIR/install.sh" reconfigure -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth7
	[ "$status" -eq 0 ]
	grep -q 'interface: eth7' "$YAML_FILE"
	grep -q -- '-i=eth7' "$NTOPNG_CONF"
	run grep -c "systemctl enable --now suricata.service" "$MOCK_CALLS_LOG"
	[ "$output" = "1" ]
	run grep -c "systemctl enable --now ntopng.service" "$MOCK_CALLS_LOG"
	[ "$output" = "1" ]
	run grep -c "evebox\|redis\|rules" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
	after_evebox=$(sha256sum "$DPISTACK_ROOT/etc/evebox/evebox.yaml" | cut -d' ' -f1)
	[ "$before_evebox" = "$after_evebox" ]
}

@test "criterion 3: a heavy key change with -y but no --force is not applied" {
	run install_base
	[ "$status" -eq 0 ]
	before_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run bash "$REPO_DIR/install.sh" reconfigure -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set PIN_VERSIONS=yes
	[ "$status" -eq 3 ]
	after_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
}

@test "criterion 3: a heavy key change with -y --force is applied" {
	run install_base
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" reconfigure -y --force \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set PIN_VERSIONS=yes
	[ "$status" -eq 0 ]
	grep -q '^PIN_VERSIONS=yes$' "$CONF_FILE"
}

@test "criterion 3: interactive heavy change declined leaves the config untouched" {
	run install_base
	[ "$status" -eq 0 ]
	before_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	input_file="$(mktemp)"
	# 11 blank answers for the basic-key questions (keep --set values),
	# then "n" for the heavy-change confirmation prompt itself.
	printf '\n\n\n\n\n\n\n\n\n\n\nn\n' >"$input_file"

	run env DPISTACK_INPUT="$input_file" bash "$REPO_DIR/install.sh" reconfigure \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set PIN_VERSIONS=yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"отменено"* ]]
	after_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
	rm -f "$input_file"
}

@test "criterion 4: a failing suricata -T on reconfigure keeps the old yaml and conf, exit 1" {
	run install_base
	[ "$status" -eq 0 ]
	before_yaml=$(sha256sum "$YAML_FILE" | cut -d' ' -f1)
	before_conf=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run env MOCK_EXIT=1 bash "$REPO_DIR/install.sh" reconfigure -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth7
	[ "$status" -eq 1 ]
	after_yaml=$(sha256sum "$YAML_FILE" | cut -d' ' -f1)
	after_conf=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$before_yaml" = "$after_yaml" ]
	[ "$before_conf" = "$after_conf" ]
}

@test "criterion 5: a manually edited file is not overwritten by reconfigure without --force" {
	run install_base
	[ "$status" -eq 0 ]
	echo "# hand edit" >>"$YAML_FILE"
	before_sum=$(sha256sum "$YAML_FILE" | cut -d' ' -f1)

	run bash "$REPO_DIR/install.sh" reconfigure -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set IFACES=eth7
	[ "$status" -eq 0 ]
	after_sum=$(sha256sum "$YAML_FILE" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
	[[ "$output" == *"изменён вручную"* ]]
}

@test "criterion 7: upgrade with PIN_VERSIONS=yes still calls apt (which itself skips held packages)" {
	run install_base --set PIN_VERSIONS=yes
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" upgrade
	[ "$status" -eq 0 ]
	[[ "$output" == *"apt сам пропустит"* ]]
	run grep -c "apt-get install --only-upgrade" "$MOCK_CALLS_LOG"
	[ "$output" = "1" ]
}

@test "criterion 9: install, uninstall --purge, install gives the same dpistack.conf" {
	run install_base --set IFACES=eth7
	[ "$status" -eq 0 ]
	first_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run bash "$REPO_DIR/install.sh" uninstall --purge
	[ "$status" -eq 0 ]
	[ ! -e "$CONF_FILE" ]

	run install_base --set IFACES=eth7
	[ "$status" -eq 0 ]
	second_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$first_sum" = "$second_sum" ]
}
