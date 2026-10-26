#!/usr/bin/env bats
# Covers slice 15: selfinstall, the persistent `dpistack` command and the
# management menu. dpistack is replaced by a stub for the menu, so the menu
# is tested on what it calls, not on the helper itself.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	SBIN="$DPISTACK_ROOT/usr/local/sbin"
	INSTALLER_DIR="$DPISTACK_ROOT/usr/local/lib/dpistack/installer"
	CONF="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	STUB_LOG="$(mktemp)"
	export STUB_LOG
	INPUT="$(mktemp)"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG" "$STUB_LOG" "$INPUT"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no "$@"
}

# stub_ctl - replaces the installed helper with one that logs its
# arguments and exits with $STUB_RC.
stub_ctl() {
	rm -f "$SBIN/dpistack-stub"
	cat >"$SBIN/dpistack-stub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
echo "stub-out: $*"
exit "${STUB_RC:-0}"
STUB
	chmod +x "$SBIN/dpistack-stub"
	export DPISTACK_BIN="$SBIN/dpistack-stub"
}

# dp_input <lines...> - menu input, one line each
dp_input() {
	printf '%s\n' "$@" >"$INPUT"
}

@test "criterion 1: dpistack exists after install and plans the same as install.sh" {
	run install_base
	[ "$status" -eq 0 ]
	[ -L "$SBIN/dpistack" ]
	[ -x "$SBIN/dpistack" ]
	[ ! -e "$SBIN/dpistack-ctl" ]
	[ -x "$SBIN/dpistack-watch" ]
	[ "$(readlink -f "$SBIN/dpistack")" = "$INSTALLER_DIR/install.sh" ]

	run bash "$REPO_DIR/install.sh" install --dry-run -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	# Log lines carry a timestamp; everything else must match exactly.
	expected="$(sed -E 's/^[0-9]{4}-[0-9T:Z-]+ //' <<<"$output")"
	run "$SBIN/dpistack" install --dry-run -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[ "$status" -eq 0 ]
	[ "$(sed -E 's/^[0-9]{4}-[0-9T:Z-]+ //' <<<"$output")" = "$expected" ]
}

@test "criterion 2: an unchanged source is not copied again, a changed one is copied over" {
	run install_base
	[ "$status" -eq 0 ]
	marker="$INSTALLER_DIR/lib/paths.sh"
	touch -d "@1000000000" "$marker"
	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[[ "$output" == *"selfinstall: ok"* ]]
	run install_base
	[ "$status" -eq 0 ]
	[ "$(stat -c %Y "$marker")" = "1000000000" ]

	# A new version of the set in a copy of the clone.
	work="$(mktemp -d)"
	(cd "$REPO_DIR" && cp -a install.sh lib templates bin tests "$work")
	echo "# newer" >>"$work/lib/paths.sh"
	run bash "$work/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[ "$status" -eq 0 ]
	grep -q "# newer" "$marker"
	rm -rf "$work"
}

@test "criterion 3: dpistack without arguments and with a config opens the management menu" {
	run install_base
	dp_input q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Managing the installed stand"* ]]
	for item in "Configure" "Component status" "Logs" "Run tests" "Upgrade packages" "Uninstall" "Panel password"; do
		[[ "$output" == *"$item"* ]]
	done
	[[ "$output" != *"Quick install"* ]]
	[[ "$output" == *"dpistack v$(grep -o '"[0-9.]*"' "$REPO_DIR/lib/common.sh" | head -1 | tr -d '"')"* ]]
}

@test "criterion 4: dpistack without arguments and without a config opens the install menu" {
	mkdir -p "$DPISTACK_ROOT/usr/local/sbin"
	ln -s "$REPO_DIR/install.sh" "$DPISTACK_ROOT/usr/local/sbin/dpistack"
	dp_input q y
	DPISTACK_INPUT="$INPUT" run "$DPISTACK_ROOT/usr/local/sbin/dpistack"
	[[ "$output" == *"Quick install"* ]]
	[[ "$output" != *"Managing the installed stand"* ]]
}

@test "criterion 5: status, logs and tests call dpistack; a failing helper keeps the menu alive" {
	run install_base
	stub_ctl
	dp_input 2 3 1 "" 4 q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	grep -qx "status" "$STUB_LOG"
	grep -qx "logs suricata -n 200" "$STUB_LOG"
	grep -qx "test all --json" "$STUB_LOG"

	: >"$STUB_LOG"
	dp_input 2 4 q
	STUB_RC=3 DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	[[ "$output" == *"dpistack returned code 3"* ]]
	[ "$(grep -c . "$STUB_LOG")" -ge 2 ]
}

@test "criterion 6: Back exists only when reconfigure is opened from the management menu" {
	run install_base
	dp_input q y
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack" reconfigure
	[[ "$output" == *"Configuring an existing installation"* ]]
	[[ "$output" != *"b) Back"* ]]

	dp_input 1 b q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Configuring an existing installation"* ]]
	[[ "$output" == *"b) Back"* ]]
	# After Back the management menu is shown again.
	[ "$(grep -o "Managing the installed stand" <<<"$output" | wc -l)" -eq 2 ]
}

@test "criterion 7: uninstall needs the word, wrong input or empty changes nothing" {
	run install_base
	for answer in "no" ""; do
		dp_input 6 "$answer" q
		DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
		[ "$status" -eq 0 ]
		[[ "$output" == *"cancelled"* ]]
		[ -f "$CONF" ]
	done
	dp_input 6 "remove" "" q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ -f "$CONF" ]
}

@test "criterion 7 and 10: confirmed uninstall removes the commands and the installer copy" {
	run install_base
	dp_input 6 "remove" 1
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	[ ! -e "$CONF" ]
	[ ! -e "$SBIN/dpistack" ]
	[ ! -e "$SBIN/dpistack-ctl" ]
	[ ! -e "$SBIN/dpistack-watch" ]
	[ ! -d "$INSTALLER_DIR" ]
	[ ! -e "$DPISTACK_ROOT/etc/systemd/system/dpistack-watch.timer" ]
	[ ! -e "$DPISTACK_ROOT/etc/sudoers.d/dpistack" ]
	[ ! -e "$DPISTACK_ROOT/etc/dpistack/panel.auth" ]
}

@test "criterion 7: choice 2 runs uninstall with --purge" {
	run install_base
	[ -f "$DPISTACK_ROOT/etc/suricata/suricata.yaml" ]
	dp_input 6 "remove" 2
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	[[ "$output" == *"--purge"* ]]
	[ ! -e "$DPISTACK_ROOT/etc/suricata/suricata.yaml" ]
}

@test "criterion 8: an explicit install with a config shows Found install, option 3 opens management" {
	run install_base
	dp_input 3 q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack" install --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"Installation found"* ]]
	[[ "$output" == *"Managing the installed stand"* ]]
}

@test "criterion 9: the verbs of the privileged side are verbs of dpistack itself, there is no second command" {
	run install_base
	[ -L "$SBIN/dpistack" ]
	[ ! -e "$SBIN/dpistack-ctl" ]
	run "$SBIN/dpistack" version
	[ "$status" -eq 0 ]
	run "$SBIN/dpistack" logs suricata -n 5000
	[ "$status" -eq 2 ]
	run "$SBIN/dpistack" status --json
	[ "$status" -eq 0 ]
	[[ "$output" == *'"components"'* ]]
}

@test "dpistack refuses to run without root, whatever the command" {
	fake="$(mktemp -d)"
	printf '#!/bin/sh\necho 1000\n' >"$fake/id"
	chmod +x "$fake/id"
	PATH="$fake:$PATH" run bash "$REPO_DIR/install.sh" version
	[ "$status" -eq 1 ]
	[[ "$output" == *"as root only"* ]]
	PATH="$fake:$PATH" run bash "$REPO_DIR/install.sh" status --json
	[ "$status" -eq 1 ]
	PATH="$fake:$PATH" run bash "$REPO_DIR/install.sh" settings list
	rm -rf "$fake"
	[ "$status" -eq 1 ]
}

@test "the panel user gets the verbs and no installer command" {
	SUDO_USER=dpistack run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 2 ]
	SUDO_USER=dpistack run bash "$REPO_DIR/install.sh" install -y
	[ "$status" -eq 2 ]
	SUDO_USER=dpistack run bash "$REPO_DIR/install.sh" version
	[ "$status" -eq 0 ]
}

@test "criterion 7 extra: the panel password from the menu goes to ctl panel-passwd via stdin" {
	run install_base
	rm -f "$SBIN/dpistack-stub"
	cat >"$SBIN/dpistack-stub" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "panel-passwd" ]]; then read -r pw; echo "len=${#pw}" >>"$STUB_LOG"; fi
echo "$*" >>"$STUB_LOG"
STUB
	chmod +x "$SBIN/dpistack-stub"
	export DPISTACK_BIN="$SBIN/dpistack-stub"
	dp_input 7 "S3cret-pass" "S3cret-pass" q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[ "$status" -eq 0 ]
	grep -qx "len=11" "$STUB_LOG"
	[[ "$output" != *"S3cret-pass"* ]]

	: >"$STUB_LOG"
	dp_input 7 "one" "two" q
	DPISTACK_INPUT="$INPUT" run "$SBIN/dpistack"
	[[ "$output" == *"the passwords do not match"* ]]
	! grep -q "panel-passwd" "$STUB_LOG"
}

@test "a dpistack-ctl link left by an earlier version is removed on install" {
	mkdir -p "$SBIN"
	ln -s "$SBIN/dpistack" "$SBIN/dpistack-ctl"
	run install_base
	[ "$status" -eq 0 ]
	[ ! -e "$SBIN/dpistack-ctl" ]
	[ ! -L "$SBIN/dpistack-ctl" ]
}
