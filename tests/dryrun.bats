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
	for step in selfinstall ndpi metrics watch; do
		[[ "$output" == *"$step ... без изменений"* ]]
	done
	# suricata, rules, redis, ntopng, evebox, access, panel have real check/apply logic by now
	# (slices 2-7, 10, 12): a fresh root has nothing installed yet, so they
	# correctly plan work instead of claiming "без изменений" - dry-run's
	# job is to not touch disk, not to pretend there is nothing to do.
	[[ "$output" == *"suricata ... нужно применить"* ]]
	[[ "$output" == *"rules ... нужно применить"* ]]
	[[ "$output" == *"redis ... нужно применить"* ]]
	[[ "$output" == *"ntopng ... нужно применить"* ]]
	[[ "$output" == *"evebox ... нужно применить"* ]]
	[[ "$output" == *"access ... нужно применить"* ]]
	[[ "$output" == *"panel ... нужно применить"* ]]
	[[ "$output" == *"verify ... нужно применить"* ]]
	[ ! -e "$CONF_FILE" ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack/state" ]
	[ ! -e "$DPISTACK_ROOT/etc/suricata/suricata.yaml" ]
}

# The interactive flow is the real menu as of slice 9 - its save/
# replay behaviour is covered in tests/menu.bats instead.

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
