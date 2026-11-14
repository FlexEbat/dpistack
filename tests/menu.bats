#!/usr/bin/env bats
# Covers slice 9 criteria 1-5, 7-12 (per tech.md's own test scope;
# criterion 6, quick install's interface picker, needs `ip -o link`
# output this suite's mocks don't model and was verified manually).
#
# Main install menu numbering: 1=quick install, 2=capture,
# 3=components, 4=eve, 5=rules, 6=access, 7=metrics, 8=watch, 9=tests,
# 10=panel password. The reconfigure menu has no quick-install item,
# so there it's 1=capture .. 8=tests, 9=panel password.
# Every screen that shows "Enter to continue" (the diff screen)
# consumes one extra input line by itself.

setup() {
	# The older tests drive the screens with fixed lines; the confirmations have tests/menu_confirm.bats.
	export DPISTACK_MENU_ASSUME_YES=1
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
	DRAFT_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf.draft"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

run_menu() {
	local input_text="$1"
	shift
	local f
	f="$(mktemp)"
	printf '%b' "$input_text" >"$f"
	run env DPISTACK_INPUT="$f" bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
	rm -f "$f"
}

@test "criterion 1: install -y never shows the menu" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" != *"Quick install"* ]]
}

@test "criterion 1: install with DPISTACK_INPUT shows the main menu" {
	run_menu "q\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Install"* ]]
	[[ "$output" == *"Quick install"* ]]
}

@test "criterion 2: no terminal, no DPISTACK_INPUT, no -y exits 2 with a hint about -y" {
	run env DPISTACK_TTY_DEV=/nonexistent bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no </dev/null
	[ "$status" -eq 2 ]
	[[ "$output" == *"-y"* ]]
}

@test "curl | bash: stdin is a pipe, the menu reads the terminal device instead" {
	local tty_file
	tty_file="$(mktemp)"
	printf 'q\ny\n' >"$tty_file"
	run bash -c "echo 'not for the menu' | env DPISTACK_TTY_DEV='$tty_file' bash '$REPO_DIR/install.sh' install --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no"
	rm -f "$tty_file"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Quick install"* ]]
	[[ "$output" != *"no terminal"* ]]
}

@test "curl | bash: reconfigure menu also finds the terminal device" {
	local tty_file
	tty_file="$(mktemp)"
	printf 'q\ny\n' >"$tty_file"
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'SURICATA_SOURCE=oisf\nNDPI_ENABLE=no\n' >"$CONF_FILE"
	run bash -c "echo x | env DPISTACK_TTY_DEV='$tty_file' bash '$REPO_DIR/install.sh' reconfigure"
	rm -f "$tty_file"
	[[ "$output" != *"no terminal"* ]]
}

@test "criterion 3: an invalid value is rejected with the allowed list, old value kept" {
	run_menu "3\n1\nbogus-value\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"invalid value, allowed: yes,no"* ]]
	[ ! -e "$CONF_FILE" ]
}

@test "criterion 3: '-' resets a key to its schema default" {
	run_menu "9\na\n3\nno\n0\n9\n3\n-\n0\n10\nmypassword123\nmypassword123\ni\n" --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -q '^TEST_ON_INSTALL=yes$' "$CONF_FILE"
}

@test "criterion 4: a changed key shows the '*' marker (differs from default)" {
	run_menu "6\n1\nlan\n6\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ACCESS_MODE                  = lan *"* ]]
}

@test "criterion 5: 'i' is refused while a cross-check problem exists" {
	run_menu "4\na\n9\nelasticsearch\n0\ni\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"cannot install while there are problems"* ]]
	[[ "$output" == *"needs EVEBOX_ES_URL"* ]]
	[ ! -e "$CONF_FILE" ]
}

@test "criterion 7: an existing dpistack.conf shows 'Installation found', not a silent overwrite" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	before_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run_menu "5\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Installation found"* ]]
	after_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
}

@test "criterion 8: a draft is written after an edit, holds no secrets, 0600, conf untouched until apply" {
	run_menu "6\n1\nlan\n0\nq\ny\n" --set ALERT_TG_TOKEN=should-not-leak
	[ "$status" -eq 0 ]
	[ -f "$DRAFT_FILE" ]
	grep -q '^ACCESS_MODE=lan$' "$DRAFT_FILE"
	run grep -c "should-not-leak\|ALERT_TG_TOKEN" "$DRAFT_FILE"
	[ "$output" = "0" ]
	[ ! -e "$CONF_FILE" ]
	perm=$(stat -c '%a' "$DRAFT_FILE")
	[ "$perm" = "600" ]
}

@test "criterion 8: a finished install removes the draft" {
	run_menu "10\nmypassword123\nmypassword123\ni\n" --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	[ -f "$CONF_FILE" ]
	[ ! -e "$DRAFT_FILE" ]
}

@test "criterion 9: quitting with unapplied edits asks for confirmation; 'n' returns to the menu" {
	run_menu "6\n1\nlan\n0\nq\nn\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Leave without applying"* ]]
	[ ! -e "$CONF_FILE" ]
}

# criterion 9 (Ctrl+C/SIGINT leaves no trace): not automated here. Two
# fifo-based approaches (a backgrounded writer, and holding a r/w
# descriptor open in this shell) were both flaky specifically under
# bats' own job control - one hit EOF before the signal arrived, the
# other never saw the signal reach the right process. Verified
# manually instead, repeatedly, outside bats: `kill -INT` on install.sh
# while it is blocked in the menu consistently exits 130, prints
# "interrupted, nothing changed", and creates neither dpistack.conf
# nor a draft. menu_on_interrupt (lib/menu.sh) is what makes this
# work - a SIGINT trap installed only while the menu's input fd is open.

@test "criterion 10: a secret is shown as 'not set'/'set', never its value" {
	run_menu "8\na\nq\ny\n" --set ALERT_CHANNELS=panel,log,tg --set ALERT_TG_TOKEN=super-secret-xyz
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALERT_TG_TOKEN               = set"* ]]
	[[ "$output" != *"super-secret-xyz"* ]]
}

@test "criterion 11: reconfigure d/a work; a failed check leaves the menu open with edits intact" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	before_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	f="$(mktemp)"
	# 1=capture, 1=IFACES, set eth7, 0=back, d=diff (+blank for its
	# own "press enter"), a=apply (mocked suricata -T fails), then
	# q+y to actually leave - if 'a' had killed the process instead of
	# returning to the menu, these would never be reached.
	printf '1\n1\neth7\n0\nd\n\na\nq\ny\n' >"$f"
	MOCK_IP_EXISTING_IFACES="enp2s0,eth7" MOCK_EXIT=1 \
		DPISTACK_INPUT="$f" run bash "$REPO_DIR/install.sh" reconfigure \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata -T failed"* ]]
	[[ "$output" == *"IFACES: enp2s0 -> eth7"* ]]
	after_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)
	[ "$before_sum" = "$after_sum" ]
}

@test "criterion 11: reconfigure 'r' discards unapplied edits" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]

	f="$(mktemp)"
	printf '1\n1\neth7\n0\nr\ny\nq\ny\n' >"$f"
	MOCK_IP_EXISTING_IFACES="enp2s0,eth7" DPISTACK_INPUT="$f" \
		run bash "$REPO_DIR/install.sh" reconfigure \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[ "$status" -eq 0 ]
	grep -q '^IFACES=enp2s0$' "$CONF_FILE"
}

@test "criterion 12: NO_COLOR strips ANSI escapes from the menu" {
	f="$(mktemp)"
	printf 'q\ny\n' >"$f"
	NO_COLOR=1 DPISTACK_INPUT="$f" run bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[[ "$output" != *$'\033['* ]]
}

@test "criterion 12: --no-color strips ANSI escapes from the menu" {
	f="$(mktemp)"
	printf 'q\ny\n' >"$f"
	DPISTACK_INPUT="$f" run bash "$REPO_DIR/install.sh" install --no-color \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[[ "$output" != *$'\033['* ]]
}

@test "every menu screen header shows the program version, same as dpistack version" {
	ver="$("$REPO_DIR/tests/helpers/verbs" version)"
	[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

	run_menu "q\ny\n"
	[[ "$output" == *"dpistack v$ver"* ]]

	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]

	f="$(mktemp)"
	printf 'q\n' >"$f"
	run env DPISTACK_INPUT="$f" bash "$REPO_DIR/install.sh" reconfigure \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[[ "$output" == *"dpistack v$ver | Configuring an existing installation"* ]]

	f="$(mktemp)"
	printf '5\n' >"$f"
	run env DPISTACK_INPUT="$f" bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[[ "$output" == *"dpistack v$ver | Installation found"* ]]
}

@test "a menu choice that is not a number is refused, it does not end the menu (R136)" {
	local in
	in="$(mktemp)"
	printf 'zz\n1 2\nq\ny\n' >"$in"
	run env DPISTACK_INPUT="$in" bash "$REPO_DIR/install.sh" install --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$in"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unclear choice: zz"* ]]
	[[ "$output" == *"unclear choice: 1 2"* ]]
	[[ "$output" != *"value too great"* && "$output" != *"syntax error"* ]]
}

@test "the reconfigure screen refuses a choice that is not a number too (R136)" {
	local in
	in="$(mktemp)"
	printf 'zz\nq\ny\n' >"$in"
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'SURICATA_SOURCE=oisf\nNDPI_ENABLE=no\n' >"$CONF_FILE"
	run env DPISTACK_INPUT="$in" bash "$REPO_DIR/install.sh" reconfigure
	rm -f "$in"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unclear choice: zz"* ]]
	[[ "$output" != *"value too great"* ]]
}

@test "a number with a leading zero is a decimal number in the menu, not a bad octal one (R142)" {
	run_menu "3\n01\nbogus-value\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"invalid value, allowed: yes,no"* ]]
	run_menu "3\n0099\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unclear choice: 0099"* ]]
	[[ "$output" != *"value too great"* ]]
}

@test "saved config, option 2: a network access is confirmed in the menu, not by a failure (report, Debian 13)" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	sed -i '/^ACCESS_MODE=/d' "$CONF_FILE"
	echo "ACCESS_MODE=lan" >>"$CONF_FILE"
	export DPISTACK_MENU_ASSUME_YES=0

	run_menu "2\nn\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"reachable from more than this machine"* ]]
	[[ "$output" == *"not confirmed, nothing was changed"* ]]

	run_menu "2\ny\n"
	[[ "$output" == *"reachable from more than this machine"* ]]
	[[ "$output" != *"needs --set ACCESS_CONFIRM=yes"* ]]
}

@test "the same applied network access is not asked again (option 2)" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	export DPISTACK_MENU_ASSUME_YES=0
	run_menu "2\n"
	[[ "$output" != *"reachable from more than this machine"* ]]
}

@test "a busy port kept with q does not start the install: the menu says so and stays (report, NTOPNG_PORT)" {
	export DPISTACK_MENU_ASSUME_YES=0
	MOCK_SS_LISTEN=3000 run_menu "n\n10\nmypassword123\nmypassword123\ni\nq\nq\ny\n" --set ACCESS_CONFIRM=yes
	[[ "$output" == *"port 3000 (NTOPNG_PORT) is already busy"* ]]
	[[ "$output" == *"the install was not started: a port is still busy"* ]]
	[ ! -e "$CONF_FILE" ]
}

@test "R193: schema_empty_meaning says what an empty optional value does, and is silent otherwise" {
	run bash -c "source '$BATS_TEST_DIRNAME/../lib/schema.sh'; schema_empty_meaning BPF_FILTER"
	[ "$status" -eq 0 ]
	[[ "$output" == *"all the traffic"* ]]
	run bash -c "source '$BATS_TEST_DIRNAME/../lib/schema.sh'; schema_empty_meaning NTOPNG_IFACES"
	[[ "$output" == *"same interfaces as Suricata"* ]]
	run bash -c "source '$BATS_TEST_DIRNAME/../lib/schema.sh'; schema_empty_meaning IFACES"
	[ -z "$output" ]
}

@test "R193: every optional key that has a free-text empty default has a meaning" {
	local key
	for key in BPF_FILTER NTOPNG_IFACES SURICATA_VERSION NDPI_VERSION NTOPNG_VERSION EVEBOX_VERSION EVE_REDIS EVE_MAX_SIZE_MB RULES_URLS; do
		run bash -c "source '$BATS_TEST_DIRNAME/../lib/schema.sh'; schema_empty_meaning $key"
		[ -n "$output" ]
	done
}

# Step 1 of the menu review (18.54): the install screen says what is wrong
# and what to do next.

@test "the install screen counts the missing panel password as a problem and says the next step" {
	run_menu "q\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Problems (1): the panel password is not set (item 10)"* ]]
	[[ "$output" == *"Next: set the panel password (item 10), then press i to install."* ]]
}

@test "with the password set the install screen has no problem and says to press i" {
	run_menu "10\nsecret-pass1\nsecret-pass1\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Problems (0)"* ]]
	[[ "$output" == *"Next: press i to install."* ]]
}

@test "e lists every problem, a cross-check problem and the missing password both" {
	run_menu "4\na\n9\nelasticsearch\n0\ne\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"(e = show all)"* ]]
	[[ "$output" == *"  - "*"needs EVEBOX_ES_URL"* ]]
	[[ "$output" == *"  - the panel password is not set"* ]]
}

@test "i without the password names the item to open" {
	run_menu "i\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unavailable without a panel password: set it with item 10"* ]]
	[ ! -e "$CONF_FILE" ]
}

@test "the under development note is printed once, not on every redraw" {
	run_menu "c\n\nq\ny\n"
	[ "$status" -eq 0 ]
	[ "$(grep -c 'Under development: dpistack is still being developed' <<<"$output")" -eq 1 ]
}

@test "the install screen has a help of its own and every item is on one column" {
	run_menu "?\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Quick install: five short questions"* ]]
	[[ "$output" == *"   1) Quick install"* ]]
	[[ "$output" == *"  10) Panel password"* ]]
}

@test "a section explains the markers that are on the screen, and only those" {
	run_menu "6\n1\nlan\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"* differs from the default"* ]]
	[[ "$output" != *"~ differs from the applied value"* ]]
}

@test "an unclear choice says what to type" {
	run_menu "zz\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unclear choice: zz (type a number or a letter from the list, ? for help)"* ]]
}

@test "0 is not a Back on a reconfigure that was opened directly, and the answer says what to type" {
	local in
	in="$(mktemp)"
	printf '0\nq\ny\n' >"$in"
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'SURICATA_SOURCE=oisf\nNDPI_ENABLE=no\n' >"$CONF_FILE"
	run env DPISTACK_INPUT="$in" bash "$REPO_DIR/install.sh" reconfigure
	rm -f "$in"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unclear choice: 0 (type a number"* ]]
}

# Step 2 of the menu review (18.54): a section says what each key is for.

@test "a section prints the hint of every key under it, and the count of the advanced keys" {
	run_menu "2\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Interfaces Suricata captures from, comma separated."* ]]
	[[ "$output" == *"show advanced (6 more)"* ]]
}

@test "a key that the other settings switch off says so in the list" {
	run_menu "2\na\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"(not used with the current settings) How IPS gets packets"* ]]
}

@test "the key editor shows the hint and ? adds the level" {
	run_menu "2\n1\n?\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"IFACES (now:"* ]]
	[[ "$output" == *"IFACES: group capture, type free, basic level"* ]]
}

@test "lib/key_hints.sh is the generated copy of the panel hints and every key has one" {
	run bash "$REPO_DIR/scripts/gen-key-hints.sh" --check
	[ "$status" -eq 0 ]
}

@test "gen-key-hints --check fails when the generated file is stale" {
	local work
	work="$(mktemp -d)"
	mkdir -p "$work/scripts" "$work/lib" "$work/panel/web/modules"
	cp "$REPO_DIR/scripts/gen-key-hints.sh" "$work/scripts/"
	cp "$REPO_DIR/lib/schema.sh" "$work/lib/"
	cp "$REPO_DIR/panel/web/modules/settings-model.js" "$work/panel/web/modules/"
	cp "$REPO_DIR/lib/key_hints.sh" "$work/lib/"
	sed -i 's/Install this control panel\./Install the panel./' "$work/panel/web/modules/settings-model.js"
	run bash "$work/scripts/gen-key-hints.sh" --check
	rm -rf "$work"
	[ "$status" -eq 1 ]
	[[ "$output" == *"out of date"* ]]
}
