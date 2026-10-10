#!/usr/bin/env bats
# Covers slice 9 criteria 1-5, 7-12 (per tech.md's own test scope;
# criterion 6, quick install's interface picker, needs `ip -o link`
# output this suite's mocks don't model and was verified manually).
#
# Main install menu numbering: 1=quick install, 2=capture,
# 3=components, 4=eve, 5=rules, 6=access, 7=metrics, 8=watch, 9=tests,
# 10=panel password. The reconfigure menu has no quick-install item,
# so there it's 1=capture .. 8=tests, 9=panel password.
# Every screen that shows "Enter для продолжения" (the diff screen)
# consumes one extra input line by itself.

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
	[[ "$output" != *"Быстрая установка"* ]]
}

@test "criterion 1: install with DPISTACK_INPUT shows the main menu" {
	run_menu "q\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Установка"* ]]
	[[ "$output" == *"Быстрая установка"* ]]
}

@test "criterion 2: no terminal, no DPISTACK_INPUT, no -y exits 2 with a hint about -y" {
	run bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no </dev/null
	[ "$status" -eq 2 ]
	[[ "$output" == *"-y"* ]]
}

@test "criterion 3: an invalid value is rejected with the allowed list, old value kept" {
	run_menu "3\n1\nbogus-value\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"недопустимое значение, допустимо: native,docker"* ]]
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
	[[ "$output" == *"нельзя установить, пока есть проблемы"* ]]
	[[ "$output" == *"требует EVEBOX_ES_URL"* ]]
	[ ! -e "$CONF_FILE" ]
}

@test "criterion 7: an existing dpistack.conf shows 'Найдена установка', not a silent overwrite" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	before_sum=$(sha256sum "$CONF_FILE" | cut -d' ' -f1)

	run_menu "4\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Найдена установка"* ]]
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
	[[ "$output" == *"Выйти без применения"* ]]
	[ ! -e "$CONF_FILE" ]
}

# criterion 9 (Ctrl+C/SIGINT leaves no trace): not automated here. Two
# fifo-based approaches (a backgrounded writer, and holding a r/w
# descriptor open in this shell) were both flaky specifically under
# bats' own job control - one hit EOF before the signal arrived, the
# other never saw the signal reach the right process. Verified
# manually instead, repeatedly, outside bats: `kill -INT` on install.sh
# while it is blocked in the menu consistently exits 130, prints
# "прервано, ничего не изменено", and creates neither dpistack.conf
# nor a draft. menu_on_interrupt (lib/menu.sh) is what makes this
# work - a SIGINT trap installed only while the menu's input fd is open.

@test "criterion 10: a secret is shown as 'не задан'/'задан', never its value" {
	run_menu "8\na\nq\ny\n" --set ALERT_CHANNELS=panel,log,tg --set ALERT_TG_TOKEN=super-secret-xyz
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALERT_TG_TOKEN               = задан"* ]]
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
	[[ "$output" == *"suricata -T упал"* ]]
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

@test "every menu screen header shows the program version, same as dpistack-ctl version" {
	ver="$("$REPO_DIR/bin/dpistack-ctl" version)"
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
	[[ "$output" == *"dpistack v$ver | Настройка существующей установки"* ]]

	f="$(mktemp)"
	printf '4\n' >"$f"
	run env DPISTACK_INPUT="$f" bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	rm -f "$f"
	[[ "$output" == *"dpistack v$ver | Найдена установка"* ]]
}

@test "usage prints the version on the first line" {
	run bash "$REPO_DIR/install.sh" install --help
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == "dpistack v"* ]]
}
