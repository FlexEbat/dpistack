#!/usr/bin/env bats
# An update can add settings, and a saved config can hold a setting with no
# value where the program needs one. `install` records them before it writes
# the config (state pending.keys), `dpistack update-keys` asks for them, and
# the panel's settings list marks them.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	MOCK_IP_EXISTING_IFACES="enp2s0,eth1"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE MOCK_CALLS_LOG
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	CONF="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	STATE="$DPISTACK_ROOT/var/lib/dpistack/state"
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
}

teardown() { rm -rf "$DPISTACK_ROOT" "$MOCK_CALLS_LOG"; }

# age_conf <KEY...> - the saved config as an older version wrote it: without these keys
age_conf() {
	local k
	for k in "$@"; do sed -i "/^${k}=/d" "$CONF"; done
}

pending_in_state() { grep -a '^pending.keys=' "$STATE" | tail -n 1 | cut -d= -f2-; }

@test "a fresh install has nothing pending" {
	run bash "$REPO_DIR/install.sh" update-keys --list
	[ "$status" -eq 0 ]
	[[ "$output" == *"no new or empty settings"* ]]
}

@test "a key that the saved config lacks is new, is recorded before the config is rewritten, and install says so" {
	age_conf CAPTURE_THREADS PCAP_MAX_MB
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"setting(s) are new in this version or empty and use their defaults: sudo dpistack update-keys"* ]]
	[[ "$(pending_in_state)" == *"CAPTURE_THREADS:new"* ]]
	[[ "$(pending_in_state)" == *"PCAP_MAX_MB:new"* ]]
	# the config now holds them with their defaults, as before
	grep -qx 'CAPTURE_THREADS=auto' "$CONF"
	# and they are still listed afterwards, with default and hint
	run bash "$REPO_DIR/install.sh" update-keys --list
	[[ "$output" == *"CAPTURE_THREADS (new, default: auto)"* ]]
	[[ "$output" == *"Capture threads per interface"* ]]
}

@test "--json lists key, kind, default and hint" {
	age_conf CAPTURE_THREADS
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	run bash "$REPO_DIR/install.sh" update-keys --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.pending[] | select(.key=="CAPTURE_THREADS") | .kind' <<<"$output")" = "new" ]
	[ "$(jq -r '.pending[] | select(.key=="CAPTURE_THREADS") | .default' <<<"$output")" = "auto" ]
	[[ "$(jq -r '.pending[] | select(.key=="CAPTURE_THREADS") | .hint' <<<"$output")" == *"Capture threads"* ]]
}

@test "a key left empty where the program needs a value is pending, one that may be empty is not" {
	sed -i 's/^FLOW_MEMCAP=.*/FLOW_MEMCAP=/; s/^BPF_FILTER=.*/BPF_FILTER=/' "$CONF"
	run bash "$REPO_DIR/install.sh" update-keys --list
	[[ "$output" == *"FLOW_MEMCAP (empty, default: 128mb)"* ]]
	[[ "$output" != *"BPF_FILTER"* ]]
}

@test "a key that does not apply is never asked: no Telegram setting without the channel" {
	age_conf ALERT_SYSLOG_PROTO DETECT_NOTIFY_SEVERITY
	run bash "$REPO_DIR/install.sh" update-keys --list
	[[ "$output" != *"ALERT_SYSLOG_PROTO"* ]]
	[[ "$output" != *"DETECT_NOTIFY_SEVERITY"* ]]
}

@test "update-keys asks each pending key, Enter keeps the default, a value is checked and saved, the list is cleared" {
	age_conf CAPTURE_THREADS PCAP_MAX_MB
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	local f
	f="$(mktemp)"
	# CAPTURE_THREADS: a bad value first, then 4; PCAP_MAX_MB: Enter
	printf 'many\n4\n\n' >"$f"
	DPISTACK_INPUT="$f" DPISTACK_NO_APPLY=1 run bash "$REPO_DIR/install.sh" update-keys
	rm -f "$f"
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 setting(s) are new in this version or empty"* ]]
	grep -qx 'CAPTURE_THREADS=4' "$CONF"
	grep -qx 'PCAP_MAX_MB=100' "$CONF"
	[ -z "$(pending_in_state)" ]
	run bash "$REPO_DIR/install.sh" update-keys --list
	[[ "$output" == *"no new or empty settings"* ]]
}

@test "an empty key is fixed by Enter: its default is offered and saved" {
	sed -i 's/^FLOW_MEMCAP=.*/FLOW_MEMCAP=/' "$CONF"
	local f
	f="$(mktemp)"
	printf '\n' >"$f"
	DPISTACK_INPUT="$f" DPISTACK_NO_APPLY=1 run bash "$REPO_DIR/install.sh" update-keys
	rm -f "$f"
	[ "$status" -eq 0 ]
	grep -qx 'FLOW_MEMCAP=128mb' "$CONF"
}

@test "x stops and leaves the rest pending, s keeps the defaults of the rest" {
	age_conf CAPTURE_THREADS PCAP_MAX_MB
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	local f
	f="$(mktemp)"
	printf 'x\n' >"$f"
	DPISTACK_INPUT="$f" DPISTACK_NO_APPLY=1 run bash "$REPO_DIR/install.sh" update-keys
	[ "$status" -eq 0 ]
	[[ "$(pending_in_state)" == *"CAPTURE_THREADS"* ]]
	printf 's\n' >"$f"
	DPISTACK_INPUT="$f" DPISTACK_NO_APPLY=1 run bash "$REPO_DIR/install.sh" update-keys
	rm -f "$f"
	[ "$status" -eq 0 ]
	[ -z "$(pending_in_state)" ]
}

@test "--yes keeps the defaults and clears the list without asking" {
	age_conf CAPTURE_THREADS
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	DPISTACK_NO_APPLY=1 run bash "$REPO_DIR/install.sh" update-keys --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"the defaults of the new or empty settings are kept"* ]]
	[ -z "$(pending_in_state)" ]
}

@test "without a terminal and without a flag update-keys refuses instead of hanging" {
	age_conf CAPTURE_THREADS
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	DPISTACK_TTY_DEV=/nonexistent run bash "$REPO_DIR/install.sh" update-keys </dev/null
	[ "$status" -eq 2 ]
	[[ "$output" == *"no terminal to ask on"* ]]
}

@test "the settings list marks the pending keys for the panel" {
	age_conf CAPTURE_THREADS
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	run bash "$REPO_DIR/install.sh" settings list --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.keys[] | select(.key=="CAPTURE_THREADS") | .pending' <<<"$output")" = "new" ]
	[ "$(jq -r '.keys[] | select(.key=="PCAP_MAX_MB") | .pending' <<<"$output")" = "" ]
}

@test "the panel may read the list and nothing else" {
	age_conf CAPTURE_THREADS
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" update-keys --json
	[ "$status" -eq 0 ]
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" update-keys --yes
	[ "$status" -eq 2 ]
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" update-keys
	[ "$status" -eq 2 ]
}
