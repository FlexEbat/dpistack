#!/usr/bin/env bats
# v0.29.1: `dpistack diagnose`: a part that does not run is reported with its
# state, the exit status and the last lines of its log.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
show)
	if [[ "$*" == *Result* ]]; then printf 'Result=exit-code\nExecMainStatus=1\n'; else echo loaded; fi
	;;
is-active)
	case "$*" in
	*suricata.service*) echo failed; exit 3 ;;
	*) echo active ;;
	esac
	;;
is-enabled) exit 0 ;;
esac
FAKE
	cat >"$FAKE_BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
if [[ " $* " == *" -k "* ]]; then
	[[ -n "${FAKE_KERNEL_LOG:-}" ]] && printf '%s\n' "$FAKE_KERNEL_LOG"
	exit 0
fi
echo "journalctl $*"
echo "suricata[1]: Error: the plugin could not be loaded"
FAKE
	printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN/dpkg-query"
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$PATH"
	export PATH
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
}

@test "a failed part is named with its exit status and the last lines of its log" {
	run "$CTL" diagnose
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata: suricata.service is failed"* ]]
	[[ "$output" == *"ExecMainStatus=1"* ]]
	[[ "$output" == *"journalctl -u suricata.service -n 25"* ]]
	[[ "$output" == *"the plugin could not be loaded"* ]]
}

@test "a part that runs is not reported" {
	run "$CTL" diagnose evebox
	[ "$status" -eq 0 ]
	[[ "$output" == *"every selected part is running"* ]]
	[[ "$output" != *"journalctl"* ]]
}

@test "an unknown part gives 2" {
	run "$CTL" diagnose frobnicate
	[ "$status" -eq 2 ]
}

# --- the environment of an EveBox that does not start ---

# evebox_down: evebox.service is failed, runs as $1, and `runuser` runs the
# command as the current user (the tests do not run as root).
evebox_down() {
	local user="$1"
	cat >"$FAKE_BIN/systemctl" <<FAKE
#!/usr/bin/env bash
case "\$1" in
show)
	case "\$*" in
	*Result*) printf 'Result=exit-code\\nExecMainStatus=101\\n' ;;
	*"-p User"*) echo "$user" ;;
	*"-p Group"*) echo "$user" ;;
	*) echo loaded ;;
	esac
	;;
is-active) echo failed; exit 3 ;;
is-enabled) exit 0 ;;
esac
FAKE
	cat >"$FAKE_BIN/runuser" <<'FAKE'
#!/usr/bin/env bash
[[ -n "${FAKE_RUNUSER_FAIL:-}" ]] && exit 1
shift 3
exec "$@"
FAKE
	chmod +x "$FAKE_BIN"/*
	mkdir -p "$DPISTACK_ROOT/var/lib/evebox"
	printf 'x' >"$DPISTACK_ROOT/var/lib/evebox/events.sqlite"
	# Run as root the directory gets another owner, so that the owner of the
	# files is never root (a unit that runs as root is not probed).
	[[ "$(id -u)" -eq 0 ]] && chown -R nobody "$DPISTACK_ROOT/var/lib/evebox"
	return 0
}

# evebox_owner - the user that owns the data directory made by evebox_down.
evebox_owner() {
	if [[ "$(id -u)" -eq 0 ]]; then echo nobody; else id -un; fi
}

@test "an evebox that is down: the environment is looked at and nothing wrong is found" {
	evebox_down "$(evebox_owner)"
	run "$CTL" diagnose evebox
	[ "$status" -eq 0 ]
	[[ "$output" == *"what a start of evebox depends on"* ]]
	[[ "$output" == *"unit runs as: $(evebox_owner)"* ]]
	[[ "$output" == *"events.sqlite:"* ]]
	[[ "$output" == *"can create files in the directory: yes"* ]]
	[[ "$output" == *"found: owner, permissions, space, inodes, temp directory and the kernel log look fine"* ]]
}

@test "an evebox data directory of another owner than the unit's user is named" {
	evebox_down daemon
	run "$CTL" diagnose evebox
	[[ "$output" == *"found: the directory belongs to $(evebox_owner), the service runs as daemon"* ]]
	[[ "$output" == *"found: events.sqlite belongs to $(evebox_owner), not to daemon"* ]]
}

@test "a service user that cannot create files next to the databases is named" {
	evebox_down "$(evebox_owner)"
	FAKE_RUNUSER_FAIL=1 run "$CTL" diagnose evebox
	[[ "$output" == *"can create files in the directory: NO"* ]]
	[[ "$output" == *"cannot create files in"* ]]
	[[ "$output" == *"-wal and -shm"* ]]
}

@test "a unit user that does not exist is named" {
	evebox_down no-such-user-xyz
	run "$CTL" diagnose evebox
	[[ "$output" == *"the unit runs as no-such-user-xyz, but there is no such user"* ]]
}

# fake_df - a `df` whose answers the test sets: FAKE_DF_ITOTAL and
# FAKE_DF_IFREE for `df -Pi`, FAKE_DF_LOW_PATH for a path that has 1 MiB free
# (every other path 10 GiB).
fake_df() {
	cat >"$FAKE_BIN/df" <<'FAKE'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [[ "$1" == -Pi ]]; then
	echo "fake ${FAKE_DF_ITOTAL:-1000000} 1 ${FAKE_DF_IFREE:-999999} 1% $2"
elif [[ -n "${FAKE_DF_LOW_PATH:-}" && "$2" == "$FAKE_DF_LOW_PATH" ]]; then
	echo "fake 20000000 19999000 1024 99% $2"
else
	echo "fake 20000000 1000 10485760 1% $2"
fi
FAKE
	chmod +x "$FAKE_BIN/df"
}

@test "a file system with no fixed inode table (btrfs) is not reported as out of inodes" {
	evebox_down "$(evebox_owner)"
	fake_df
	FAKE_DF_ITOTAL=0 FAKE_DF_IFREE=0 run "$CTL" diagnose evebox
	[[ "$output" == *"no fixed number of inodes"* ]]
	[[ "$output" != *"almost no free inodes"* ]]
	[[ "$output" == *"found: owner, permissions, space, inodes, temp directory and the kernel log look fine"* ]]
}

@test "a file system that has an inode table and is nearly out of inodes is still named" {
	evebox_down "$(evebox_owner)"
	fake_df
	FAKE_DF_ITOTAL=1000 FAKE_DF_IFREE=5 run "$CTL" diagnose evebox
	[[ "$output" == *"5 inodes free"* ]]
	[[ "$output" == *"found: almost no free inodes"* ]]
}

@test "the temp directory SQLite would use is shown with its file system" {
	evebox_down "$(evebox_owner)"
	fake_df
	run "$CTL" diagnose evebox
	[[ "$output" == *"temp directory for $(evebox_owner): "* ]]
	[[ "$output" == *"KiB free)"* ]]
}

@test "a temp directory with almost no space left is named" {
	evebox_down "$(evebox_owner)"
	fake_df
	local tmp
	tmp="$(mktemp -d)"
	TMPDIR="$tmp" FAKE_DF_LOW_PATH="$tmp" run "$CTL" diagnose evebox
	rmdir "$tmp"
	[[ "$output" == *"found: less than 50 MiB free in $tmp, the temp directory SQLite uses"* ]]
}

@test "a service user that can use no temp directory is named" {
	evebox_down "$(evebox_owner)"
	# `runuser` succeeds for the directory probe (mktemp) and fails for the
	# temp directory probe (sh -c).
	cat >"$FAKE_BIN/runuser" <<'FAKE'
#!/usr/bin/env bash
shift 3
[[ "$1" == sh ]] && exit 1
exec "$@"
FAKE
	chmod +x "$FAKE_BIN/runuser"
	run "$CTL" diagnose evebox
	[[ "$output" == *"temp directory for $(evebox_owner): none usable"* ]]
	[[ "$output" == *"can use none of /var/tmp, /usr/tmp and /tmp"* ]]
}

@test "a missing data directory is named" {
	evebox_down "$(evebox_owner)"
	rm -rf "$DPISTACK_ROOT/var/lib/evebox"
	run "$CTL" diagnose evebox
	[[ "$output" == *"found: the data directory does not exist"* ]]
}

@test "the environment is shown for evebox only" {
	run "$CTL" diagnose suricata
	[[ "$output" != *"what a start of evebox depends on"* ]]
}

# --- the installer itself (v0.29.1) ---

install_with_dead_suricata() {
	local dir
	dir="$(mktemp -d)"
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	cat >"$dir/systemctl" <<FAKE
#!/usr/bin/env bash
if [[ "\$1" == is-active && "\$*" == *suricata.service* ]]; then echo failed; exit 3; fi
if [[ "\$1" == show && "\$*" == *Result* ]]; then printf 'Result=exit-code\nExecMainStatus=1\n'; exit 0; fi
if [[ "\$1" == show ]]; then echo loaded; exit 0; fi
exec "$REPO_DIR/tests/mocks/systemctl" "\$@"
FAKE
	cat >"$dir/journalctl" <<'FAKE'
#!/usr/bin/env bash
echo "suricata[1]: Error: the plugin could not be loaded"
FAKE
	chmod +x "$dir"/*
	PATH="$dir:$REPO_DIR/tests/mocks:$PATH" MOCK_IP_EXISTING_IFACES=enp2s0 MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log" \
		bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
}

@test "the install says why a part is dead and ends with a warning naming it" {
	run install_with_dead_suricata
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata ... partly applied"* ]]
	[[ "$output" == *"suricata: suricata.service is failed"* ]]
	[[ "$output" == *"the plugin could not be loaded"* ]]
	[[ "$output" == *"WARNING: not running after the install: suricata"* ]]
}

@test "a part that runs gives no warning" {
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_IP_EXISTING_IFACES=enp2s0 MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log" \
		run bash -c "printf 'ID=ubuntu\nID_LIKE=debian\n' >'$DPISTACK_ROOT/etc/os-release' 2>/dev/null || { mkdir -p '$DPISTACK_ROOT/etc'; printf 'ID=ubuntu\nID_LIKE=debian\n' >'$DPISTACK_ROOT/etc/os-release'; }; bash '$REPO_DIR/install.sh' install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no"
	[ "$status" -eq 0 ]
	[[ "$output" != *"WARNING: not running"* ]]
}

@test "an AppArmor denial for evebox in the kernel log is shown and named" {
	evebox_down "$(evebox_owner)"
	FAKE_KERNEL_LOG='audit: type=1400 apparmor="DENIED" operation="mknod" profile="evebox" name="/var/tmp/etilqs_1" comm="evebox"' run "$CTL" diagnose evebox
	[[ "$output" == *"kernel log: a security module refused something to evebox"* ]]
	[[ "$output" == *'name="/var/tmp/etilqs_1"'* ]]
	[[ "$output" == *"found: AppArmor or SELinux denied evebox an operation"* ]]
	[[ "$output" != *"the kernel log look fine"* ]]
}

@test "denials of another program in the kernel log are not blamed on evebox" {
	evebox_down "$(evebox_owner)"
	FAKE_KERNEL_LOG='audit: type=1400 apparmor="DENIED" operation="open" profile="/usr/sbin/cupsd" name="/etc/x" comm="cupsd"' run "$CTL" diagnose evebox
	[[ "$output" != *"a security module refused"* ]]
	[[ "$output" == *"the kernel log look fine"* ]]
}
