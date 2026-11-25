#!/usr/bin/env bats
# Scheduled backups: `dpistack backup run`, BACKUP_KEEP, BACKUP_DIR,
# BACKUP_AGE_RECIPIENT, the timer, and a restore onto an empty host.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	export MOCK_CALLS_LOG
	E="$DPISTACK_ROOT/etc"
	mkdir -p "$E/dpistack" "$E/suricata/rules" "$E/evebox"
	printf 'ACCESS_MODE=localhost\nBACKUP_SCHEDULE=daily\nBACKUP_KEEP=3\n' >"$E/dpistack/dpistack.conf"
	printf '{"users":[{"name":"admin","role":"admin","hash":"h"}]}\n' >"$E/dpistack/users.json"
	chmod 0640 "$E/dpistack/users.json"
	printf 'a: 1\n' >"$E/evebox/evebox.yaml"
	printf 'alert tcp any any -> any any (msg:"one"; sid:1000001; rev:1;)\n' >"$E/suricata/rules/local.rules"
	BDIR="$DPISTACK_ROOT/var/backups/dpistack"
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

need_age() {
	command -v age >/dev/null 2>&1 || skip "age is not installed"
	command -v age-keygen >/dev/null 2>&1 || skip "age-keygen is not installed"
}

make_key() {
	age-keygen -o "$DPISTACK_ROOT/key.txt" >/dev/null 2>&1
	RECIPIENT=$(age-keygen -y "$DPISTACK_ROOT/key.txt")
	printf 'BACKUP_AGE_RECIPIENT=%s\n' "$RECIPIENT" >>"$E/dpistack/dpistack.conf"
}

@test "run writes an archive into BACKUP_DIR, mode 0700 for the directory and the file private" {
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	[ "$(stat -c %a "$BDIR")" = "700" ]
	n=$(ls "$BDIR"/dpistack-backup-*.tar.gz | wc -l)
	[ "$n" -eq 1 ]
	f=$(ls "$BDIR"/dpistack-backup-*.tar.gz)
	[ "$(stat -c %a "$f")" = "600" ]
	run tar -tzf "$f"
	[[ "$output" == *manifest.json* ]]
	[[ "$output" == *files/users.json* ]]
	# nothing was left in the panel's archive directory
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack/archives" ] || [ -z "$(ls "$DPISTACK_ROOT/var/lib/dpistack/archives")" ]
}

@test "run keeps the newest BACKUP_KEEP and deletes the older ones, and only its own names" {
	mkdir -p "$BDIR"
	for i in 1 2 3 4 5; do
		: >"$BDIR/dpistack-backup-2020010${i}T000000Z.tar.gz"
		touch -d "2020-01-0$i" "$BDIR/dpistack-backup-2020010${i}T000000Z.tar.gz"
	done
	printf 'mine\n' >"$BDIR/notes.txt"
	touch -d "2019-01-01" "$BDIR/notes.txt"
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	[ "$(ls "$BDIR"/dpistack-backup-*.tar.gz | wc -l)" -eq 3 ]
	[ -f "$BDIR/notes.txt" ]
	[ ! -e "$BDIR/dpistack-backup-20200101T000000Z.tar.gz" ]
	[ ! -e "$BDIR/dpistack-backup-20200102T000000Z.tar.gz" ]
	[ ! -e "$BDIR/dpistack-backup-20200103T000000Z.tar.gz" ]
	[ -e "$BDIR/dpistack-backup-20200105T000000Z.tar.gz" ]
}

@test "BACKUP_DIR names another directory" {
	printf 'BACKUP_DIR=/srv/arch\n' >>"$E/dpistack/dpistack.conf"
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	[ "$(ls "$DPISTACK_ROOT/srv/arch"/dpistack-backup-*.tar.gz | wc -l)" -eq 1 ]
	[ ! -e "$BDIR" ]
}

@test "a key that is set makes an encrypted archive and leaves no plain copy" {
	need_age
	make_key
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	[ "$(ls "$BDIR"/dpistack-backup-*.tar.gz.age | wc -l)" -eq 1 ]
	[ "$(ls "$BDIR" | grep -c '\.tar\.gz$')" -eq 0 ]
	f=$(ls "$BDIR"/dpistack-backup-*.tar.gz.age)
	# the host holds only the public key: the archive is not a tar.gz
	run tar -tzf "$f"
	[ "$status" -ne 0 ]
	# and nothing readable of users.json is in the file
	run grep -c '"users"' "$f"
	[ "$output" = "0" ]
}

@test "an encrypted archive is verified and restored with the key file, and only with it" {
	need_age
	make_key
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	f=$(ls "$BDIR"/dpistack-backup-*.tar.gz.age)
	run "$CTL" backup verify "$f"
	[ "$status" -eq 3 ]
	[[ "$output" == *"--identity"* ]]
	age-keygen -o "$DPISTACK_ROOT/other.txt" >/dev/null 2>&1
	run "$CTL" backup verify "$f" --identity "$DPISTACK_ROOT/other.txt"
	[ "$status" -eq 3 ]
	[[ "$output" == *"could not open"* ]]
	run "$CTL" backup verify "$f" --identity "$DPISTACK_ROOT/key.txt"
	[ "$status" -eq 0 ]
	[[ "$output" == ok:* ]]
}

@test "a restore onto an empty host from an encrypted archive brings every file back" {
	need_age
	make_key
	printf 'sid1\n' >"$E/suricata/disable.conf"
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	f=$(ls "$BDIR"/dpistack-backup-*.tar.gz.age)
	cp "$E/dpistack/users.json" "$DPISTACK_ROOT/users.before"
	cp "$E/suricata/rules/local.rules" "$DPISTACK_ROOT/rules.before"
	# a new host: the archive and the key are all that is carried over
	cp "$f" "$DPISTACK_ROOT/carried.tar.gz.age"
	rm -rf "$E" "$DPISTACK_ROOT/var"
	mkdir -p "$E/dpistack"
	run "$CTL" backup restore "$DPISTACK_ROOT/carried.tar.gz.age" --identity "$DPISTACK_ROOT/key.txt"
	[ "$status" -eq 0 ]
	cmp "$E/dpistack/users.json" "$DPISTACK_ROOT/users.before"
	cmp "$E/suricata/rules/local.rules" "$DPISTACK_ROOT/rules.before"
	[ "$(cat "$E/suricata/disable.conf")" = "sid1" ]
	grep -q '^BACKUP_SCHEDULE=daily$' "$E/dpistack/dpistack.conf"
	[ "$(stat -c %a "$E/dpistack/users.json")" = "640" ]
}

@test "the panel cannot run a backup or name a key file" {
	run env DPISTACK_CALLER=panel "$CTL" backup run
	[ "$status" -eq 5 ]
	run env DPISTACK_CALLER=panel "$CTL" backup verify x.tar.gz --identity /etc/shadow
	[ "$status" -eq 5 ]
	run env DPISTACK_CALLER=panel "$CTL" backup restore x.tar.gz --identity /etc/shadow
	[ "$status" -eq 5 ]
}

@test "list shows the scheduled archives, an encrypted one by its name" {
	need_age
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	make_key
	sleep 1
	run "$CTL" backup run
	[ "$status" -eq 0 ]
	run "$CTL" backup list --json
	[ "$status" -eq 0 ]
	[ "$(jq 'length' <<<"$output")" -eq 2 ]
	[ "$(jq '[.[] | select(.encrypted == true)] | length' <<<"$output")" -eq 1 ]
	[ "$(jq '[.[] | select(.files == 4)] | length' <<<"$output")" -eq 1 ]
}

@test "run stops with a message when a key is set and age is missing" {
	printf 'BACKUP_AGE_RECIPIENT=age1%s\n' "$(printf 'q%.0s' $(seq 1 58))" >>"$E/dpistack/dpistack.conf"
	mkdir -p "$DPISTACK_ROOT/bin-noage"
	for t in bash jq tar gzip sha256sum stat date mkdir chmod cp mv rm mktemp cat grep tail ls wc sort cut tr diff getent dirname basename readlink env head sed awk id; do
		p=$(command -v "$t") && ln -sf "$p" "$DPISTACK_ROOT/bin-noage/$t"
	done
	run env PATH="$DPISTACK_ROOT/bin-noage" "$CTL" backup run
	[ "$status" -eq 1 ]
	[[ "$output" == *"age is not installed"* ]]
	[ ! -e "$BDIR" ] || [ -z "$(ls "$BDIR")" ]
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no "$@"
}

@test "install with a schedule writes the timer and service and starts the timer" {
	rm -rf "$E"
	mkdir -p "$E"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	run install_base --set BACKUP_SCHEDULE=weekly
	[ "$status" -eq 0 ]
	T="$E/systemd/system/dpistack-backup.timer"
	S="$E/systemd/system/dpistack-backup.service"
	grep -qx 'OnCalendar=weekly' "$T"
	grep -qx 'Persistent=true' "$T"
	grep -q '^ExecStart=.*/dpistack backup run$' "$S"
	grep -q '^systemctl enable --now dpistack-backup.timer' "$MOCK_CALLS_LOG"
	[ -d "$BDIR" ]
}

@test "the default schedule is off: no backup units are written" {
	rm -rf "$E"
	mkdir -p "$E"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	run install_base
	[ "$status" -eq 0 ]
	[ ! -e "$E/systemd/system/dpistack-backup.timer" ]
	[ ! -e "$E/systemd/system/dpistack-backup.service" ]
}

@test "turning the schedule off removes the units and keeps the archives" {
	rm -rf "$E"
	mkdir -p "$E"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	run install_base --set BACKUP_SCHEDULE=daily
	[ "$status" -eq 0 ]
	mkdir -p "$BDIR"
	: >"$BDIR/dpistack-backup-20200101T000000Z.tar.gz"
	run bash "$REPO_DIR/install.sh" reconfigure -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set BACKUP_SCHEDULE=off
	[ "$status" -eq 0 ]
	[ ! -e "$E/systemd/system/dpistack-backup.timer" ]
	[ -e "$BDIR/dpistack-backup-20200101T000000Z.tar.gz" ]
}

@test "uninstall removes the units and leaves BACKUP_DIR alone, even with --purge" {
	rm -rf "$E"
	mkdir -p "$E"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	run install_base --set BACKUP_SCHEDULE=daily
	[ "$status" -eq 0 ]
	mkdir -p "$BDIR"
	: >"$BDIR/dpistack-backup-20200101T000000Z.tar.gz"
	run bash "$REPO_DIR/install.sh" uninstall -y --purge
	[ "$status" -eq 0 ]
	[ ! -e "$E/systemd/system/dpistack-backup.timer" ]
	[ ! -e "$E/systemd/system/dpistack-backup.service" ]
	[ -e "$BDIR/dpistack-backup-20200101T000000Z.tar.gz" ]
}

@test "the schedule must be a calendar systemd accepts, and a key needs a schedule" {
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	rm -f "$E/dpistack/dpistack.conf"
	run bash "$REPO_DIR/install.sh" install -y --dry-run --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set 'BACKUP_SCHEDULE=$(reboot)'
	[ "$status" -ne 0 ]
	run bash "$REPO_DIR/install.sh" install -y --dry-run --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set BACKUP_KEEP=0
	[ "$status" -ne 0 ]
	run bash "$REPO_DIR/install.sh" install -y --dry-run --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set BACKUP_DIR=relative/path
	[ "$status" -ne 0 ]
	run bash "$REPO_DIR/install.sh" install -y --dry-run --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set "BACKUP_AGE_RECIPIENT=age1$(printf 'q%.0s' $(seq 1 58))"
	[ "$status" -ne 0 ]
	[[ "$output" == *"BACKUP_SCHEDULE=off"* ]]
}
