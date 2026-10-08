#!/usr/bin/env bats
# Covers the slice 10 part of the panel step: user and sudoers rule.

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
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	SUDOERS="$DPISTACK_ROOT/etc/sudoers.d/dpistack"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "sudoers rule names only dpistack-ctl, mode 0440, checked by visudo" {
	run install_base
	[ "$status" -eq 0 ]
	[ "$(grep -v '^#' "$SUDOERS")" = "dpistack ALL=(root) NOPASSWD: $DPISTACK_ROOT/usr/local/sbin/dpistack-ctl" ]
	[ "$(stat -c %a "$SUDOERS")" = "440" ]
	grep -q "^visudo -cf " "$MOCK_CALLS_LOG"
}

@test "a rejected sudoers file is not written and the install stops with code 1" {
	# A failing visudo only for this test; the other mocks stay healthy.
	bad_bin="$(mktemp -d)"
	printf '#!/usr/bin/env bash\necho "visudo: parse error" >&2\nexit 1\n' >"$bad_bin/visudo"
	chmod +x "$bad_bin/visudo"
	PATH="$bad_bin:$PATH" run install_base
	rm -rf "$bad_bin"
	[ "$status" -eq 1 ]
	[ ! -e "$SUDOERS" ]
}

@test "second run reports panel unchanged; hand-edited sudoers needs --force" {
	run install_base
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[[ "$output" == *"panel: в порядке"* ]]

	echo "# hand edit" >>"$SUDOERS"
	run install_base
	[ "$status" -eq 0 ]
	grep -q "hand edit" "$SUDOERS"
}

@test "dry-run writes no sudoers file and calls no useradd" {
	run bash "$REPO_DIR/install.sh" install -y --dry-run \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[ ! -e "$SUDOERS" ]
	run grep -c "^useradd\|^visudo" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
}

@test "install -y writes the panel password as argon2id, 0640, group set once the user exists" {
	run install_base
	[ "$status" -eq 0 ]
	auth="$DPISTACK_ROOT/etc/dpistack/panel.auth"
	[[ "$(cat "$auth")" == '$argon2id$'* ]]
	[ "$(stat -c %a "$auth")" = "640" ]
	grep -q "^chown root:dpistack $auth" "$MOCK_CALLS_LOG"

	# A second run keeps the existing hash.
	before="$(cat "$auth")"
	run install_base
	[ "$(cat "$auth")" = "$before" ]
}
