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
	for step in ndpi metrics; do
		[[ "$output" == *"$step ... без изменений"* ]]
	done
	# suricata, rules, redis, ntopng, evebox, access, panel have real check/apply logic by now
	# (slices 2-7, 10, 12, 13, 15): a fresh root has nothing installed yet, so they
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
	[[ "$output" == *"watch ... нужно применить"* ]]
	[[ "$output" == *"selfinstall ... нужно применить"* ]]
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

@test "install --dry-run -y does not write panel.auth or print a panel password (R81)" {
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[ ! -e "$DPISTACK_ROOT/etc/dpistack/panel.auth" ]
	[[ "$output" != *"Создан пароль панели"* ]]

	DPISTACK_PANEL_PASSWORD="dry-run-secret-123" run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[ ! -e "$DPISTACK_ROOT/etc/dpistack/panel.auth" ]
	[[ "$output" != *"dry-run-secret-123"* ]]
}

@test "an option that needs a value and gets none exits 2 instead of looping forever" {
	for opt in --set --config --only --skip; do
		run timeout 10 bash "$REPO_DIR/install.sh" install "$opt"
		[ "$status" -eq 2 ]
		[[ "$output" == *"нет значения"* ]]
	done
}

@test "uninstall --dry-run removes nothing: conf, secrets and state stay" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/var/lib/dpistack"
	echo 'SURICATA_SOURCE=oisf' >"$CONF_FILE"
	echo 'METRICS_TOKEN=x' >"$DPISTACK_ROOT/etc/dpistack/secrets.conf"
	echo 'step.suricata.status=done' >"$DPISTACK_ROOT/var/lib/dpistack/state"
	run bash "$REPO_DIR/install.sh" uninstall --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"dry-run"* ]]
	[ -f "$CONF_FILE" ]
	[ -f "$DPISTACK_ROOT/etc/dpistack/secrets.conf" ]
	grep -q 'step.suricata.status=done' "$DPISTACK_ROOT/var/lib/dpistack/state"
}

@test "a dry run does not record the hash of a file it did not write, so the real run still updates it" {
	cat >"$BATS_TEST_TMPDIR/t.sh" <<'EOF_T'
source "$REPO_DIR/lib/paths.sh"
source "$REPO_DIR/lib/common.sh"
source "$REPO_DIR/lib/state.sh"
f="$DPISTACK_ROOT/etc/f.conf"
echo old >"$f"
DRY_RUN=1 write_rendered_file "$f" "new content"
DRY_RUN=0 write_rendered_file "$f" "new content"
cat "$f"
EOF_T
	run env REPO_DIR="$REPO_DIR" bash "$BATS_TEST_TMPDIR/t.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"new content"* ]]
	[[ "$output" != *"изменён вручную"* ]]
}
