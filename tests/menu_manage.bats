#!/usr/bin/env bats
# Step 4 of the menu review (18.54): the control menu has submenus for what
# used to be command-line only. Every submenu calls the same verb a person
# would type, so a stub that logs its arguments is enough to see what ran.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH MOCK_IP_EXISTING_IFACES="enp2s0"
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	SBIN="$DPISTACK_ROOT/usr/local/sbin"
	STUB_LOG="$(mktemp)"
	export STUB_LOG
	INPUT="$(mktemp)"
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no >/dev/null 2>&1
	cat >"$SBIN/dpistack-stub" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
if [[ "$1 $2" == "status --json" ]]; then
	echo '{"components":[{"id":"suricata","state":"active"},{"id":"panel","state":"active"},{"id":"ntopng","state":"absent"}]}'
	exit 0
fi
[[ "$1 $2" == "users add" ]] && cat >/dev/null
echo "stub-out: $*"
exit "${STUB_RC:-0}"
STUB
	chmod +x "$SBIN/dpistack-stub"
	export DPISTACK_BIN="$SBIN/dpistack-stub"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG" "$STUB_LOG" "$INPUT"
}

# menu <lines...> - the control menu fed with one line per argument. The
# confirmations answer yes unless a test sets ASK=1 and gives its own answers.
menu() {
	printf '%s\n' "$@" >"$INPUT"
	if [[ "${ASK:-0}" == "1" ]]; then
		DPISTACK_INPUT="$INPUT" run env -u DPISTACK_MENU_ASSUME_YES "$SBIN/dpistack"
	else
		DPISTACK_INPUT="$INPUT" DPISTACK_MENU_ASSUME_YES=1 run "$SBIN/dpistack"
	fi
}

logged() { grep -qxF -- "$1" "$STUB_LOG"; }
not_logged() { ! grep -qxF -- "$1" "$STUB_LOG"; }
not_logged_re() { ! grep -q -- "$1" "$STUB_LOG"; }

@test "the control menu lists the submenus and shows the mode in its header" {
	menu q
	[ "$status" -eq 0 ]
	[[ "$output" == *"s) Start, stop, restart"* && "$output" == *"k) Backup"* && "$output" == *"c) Checks and addresses"* ]]
	[[ "$output" == *"mode: ids"* ]]
}

@test "services: lists the installed components with their state, restart, reload and start call the verbs" {
	menu s 1 1 1 4 1 3 0 q
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata"*"active"* ]]
	[[ "$output" != *"ntopng"*"absent"* ]]
	logged "restart suricata"
	logged "reload suricata"
	logged "start suricata"
}

@test "services: a stop that is not confirmed does not run, a confirmed one does" {
	ASK=1 menu s 2 2 n 0 q
	[ "$status" -eq 0 ]
	not_logged "stop panel"
	: >"$STUB_LOG"
	ASK=1 menu s 2 2 y 0 q
	logged "stop panel"
}

@test "rules: update, search, and turning a rule on or off call the verbs" {
	menu r 1 4 bittorrent 5 2001 disable 0 q
	[ "$status" -eq 0 ]
	logged "rules-update"
	logged "rules-search bittorrent"
	logged "rules-sid disable 2001"
	[[ "$output" == *"takes effect at the next rules update"* ]]
}

@test "rules: a rule number that is not digits is refused before any call" {
	menu r 5 "20;01" 0 q
	[ "$status" -eq 0 ]
	[[ "$output" == *"a rule number is digits only"* ]]
	not_logged_re '^rules-sid'
}

@test "mode: IPS is kept only when the person types yes, otherwise it is left to roll back" {
	ASK=1 menu m 2 y yes 0 q
	[ "$status" -eq 0 ]
	logged "mode ips --confirm-timeout 120"
	logged "mode-confirm"
	: >"$STUB_LOG"
	ASK=1 menu m 2 y no 0 q
	logged "mode ips --confirm-timeout 120"
	not_logged "mode-confirm"
	[[ "$output" == *"the switch rolls back by itself"* ]]
}

@test "mode: shows mode and interfaces, adds an interface after a confirmation" {
	menu m 3 enp3s0 0 q
	[ "$status" -eq 0 ]
	logged "mode status"
	logged "iface list"
	logged "iface add enp3s0"
}

@test "backup: a restore shows the dry run first and runs only after a yes" {
	ASK=1 menu k 4 /tmp/b.tar.gz n 0 q
	[ "$status" -eq 0 ]
	logged "backup restore /tmp/b.tar.gz --dry-run"
	not_logged "backup restore /tmp/b.tar.gz"
	: >"$STUB_LOG"
	ASK=1 menu k 4 /tmp/b.tar.gz y 0 q
	logged "backup restore /tmp/b.tar.gz --dry-run"
	logged "backup restore /tmp/b.tar.gz"
}

@test "users: add reads the password twice and passes it on stdin, never in the arguments" {
	menu u 2 bob viewer "S3cret-pass!" "S3cret-pass!" 0 q
	[ "$status" -eq 0 ]
	logged "users add bob viewer"
	not_logged_re 'S3cret'
}

@test "users: passwords that differ change nothing, a wrong role is refused" {
	menu u 2 bob viewer one-pass two-pass 2 bob root 0 q
	[ "$status" -eq 0 ]
	[[ "$output" == *"the passwords do not match, nothing changed"* ]]
	[[ "$output" == *"the role is one of viewer, analyst, operator, admin"* ]]
	not_logged_re '^users add'
}

@test "users: removing a user and ending a token ask first" {
	ASK=1 menu u 5 bob n 7 abc123 n 0 q
	[ "$status" -eq 0 ]
	not_logged_re '^users remove'
	not_logged_re '^tokens revoke'
	: >"$STUB_LOG"
	ASK=1 menu u 5 bob y 7 abc123 y 0 q
	logged "users remove bob"
	logged "tokens revoke abc123"
}

@test "checks: addresses, health, diagnose, security check and the support report call the verbs" {
	menu c 1 2 3 4 5 0 q
	[ "$status" -eq 0 ]
	logged "info"
	logged "health"
	logged "diagnose"
	logged "security check"
	logged "diag"
}

@test "every submenu goes back on Enter or 0 and says what to type on a wrong answer" {
	menu s "" m 0 r "" k 0 u "" c 0 q
	[ "$status" -eq 0 ]
	[[ "$output" != *"unclear choice"* ]]
	menu r zz 0 q
	[[ "$output" == *"unclear choice: zz (type a number or a letter from the list, ? for help)"* ]]
}
