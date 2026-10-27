#!/usr/bin/env bats
# v0.25.0: components chosen one by one, a confirmation before every action
# of the menu, an exit on every screen, the guided setup that asks everything.
# These tests do NOT set DPISTACK_MENU_ASSUME_YES: the questions are real.

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
	unset DPISTACK_MENU_ASSUME_YES
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

run_menu() {
	local f
	f="$(mktemp)"
	printf '%b' "$1" >"$f"
	shift
	run env DPISTACK_INPUT="$f" bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
	rm -f "$f"
}

# Fresh install: "n" to the guided setup question goes to the main menu.

@test "a fresh install offers the guided setup first, and n skips it" {
	run_menu "n\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Run the guided setup first"* ]]
	[[ "$output" == *"Quick install"* ]]
}

@test "the components screen lists every part and has an exit" {
	run_menu "n\nm\n0\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Choose components"* ]]
	[[ "$output" == *"Suricata (IDS/IPS engine)"* ]]
	[[ "$output" == *"nDPI plugin for Suricata"* ]]
	[[ "$output" == *"EveBox (alert viewer)"* ]]
	[[ "$output" == *"ntopng with Redis"* ]]
	[[ "$output" == *"Metrics storage"* ]]
	[[ "$output" == *"0) back"* ]]
}

@test "switching a component off asks first and then switches it" {
	run_menu "n\nm\n4\ny\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Switch EveBox (alert viewer) off?"* ]]
	[[ "$output" == *"[ ] EveBox (alert viewer)"* ]]
}

@test "declining the confirmation leaves the component as it was" {
	run_menu "n\nm\n4\nn\n0\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"not changed"* ]]
	[[ "$output" != *"[ ] EveBox (alert viewer)"* ]]
}

@test "0 cancels a confirmation as well" {
	run_menu "n\nm\n4\n0\n0\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"not changed"* ]]
}

@test "switching Suricata off takes nDPI and the rules with it" {
	run_menu "n\nm\n1\ny\n0\nq\ny\n" --set NDPI_ENABLE=yes --set SURICATA_SOURCE=source
	[ "$status" -eq 0 ]
	[[ "$output" == *"nDPI and the rules go off with it"* ]]
	[[ "$output" == *"[ ] nDPI plugin for Suricata"* ]]
	[[ "$output" == *"[ ] Rules and their update"* ]]
}

@test "nDPI cannot be switched on while Suricata is off" {
	run_menu "n\nm\n1\ny\n2\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"works only together with Suricata"* ]]
}

@test "editing a key asks for a confirmation and a declined one keeps the value" {
	run_menu "n\n3\n1\nno\nn\n0\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Set SURICATA_ENABLE = no?"* ]]
	[[ "$output" == *"not changed"* ]]
}

@test "the key editor can be left with the word cancel" {
	run_menu "n\n3\n1\ncancel\n0\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Enter or cancel = leave"* ]]
}

@test "check, plan, save and load ask before they act" {
	run_menu "n\nc\nn\np\nn\ns\n\nl\n\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Check the system (nothing is changed)?"* ]]
	[[ "$output" == *"Show the plan (nothing is changed)?"* ]]
}

@test "the panel password screen can be left" {
	run_menu "n\n10\n!cancel\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"!cancel = leave without setting"* ]]
}

@test "the guided setup asks the settings of the chosen parts and skips the others" {
	# components screen: leave at once; then every group is declined except capture
	run_menu "y\n0\nn\nn\nn\nn\nn\nn\nn\nn\nq\n" --set EVEBOX_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"Guided setup"* ]]
	[[ "$output" == *"Go through this group?"* ]]
}

@test "the guided setup asks the advanced keys too, and leaves on x" {
	run_menu "y\n0\ny\n\n\n\nx\ny\nq\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"SURICATA_MODE"* ]]
	[[ "$output" == *"Leave the guided setup"* ]]
}

@test "the guided setup skips the keys of a part that is switched off" {
	run_menu "y\n0\nn\ny\n\n\n\n\n\n\n\n\nn\ny\ns\nn\nn\nn\nn\nq\n" --set EVEBOX_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"EVE_KEEP (now"* ]]
	[[ "$output" != *"EVEBOX_PORT (now"* ]]
	[[ "$output" != *"EVEBOX_RETENTION_DAYS (now"* ]]
}

@test "install -y with a part switched off reports it as skipped in the plan" {
	run bash "$REPO_DIR/install.sh" install -y --dry-run \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set EVEBOX_ENABLE=no --set NTOPNG_ENABLE=no --set PANEL_ENABLE=no --set RULES_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"[5/15] rules ... no changes"* ]]
	[[ "$output" == *"[6/15] redis ... no changes"* ]]
	[[ "$output" == *"[7/15] ntopng ... no changes"* ]]
	[[ "$output" == *"[8/15] evebox ... no changes"* ]]
	[[ "$output" == *"[13/15] panel ... no changes"* ]]
}

@test "Suricata off with nDPI or rules on is refused with a clear text" {
	run bash "$REPO_DIR/install.sh" install -y --dry-run --set SURICATA_ENABLE=no
	[ "$status" -eq 2 ]
	[[ "$output" == *"SURICATA_ENABLE=no with NDPI_ENABLE=yes"* ]]
	[[ "$output" == *"SURICATA_ENABLE=no with RULES_ENABLE=yes"* ]]
}

@test "Suricata off together with nDPI and rules off plans no suricata step" {
	run bash "$REPO_DIR/install.sh" install -y --dry-run \
		--set SURICATA_ENABLE=no --set NDPI_ENABLE=no --set RULES_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"[4/15] suricata ... no changes"* ]]
	[[ "$output" == *"[15/15] verify ... no changes"* ]]
}
