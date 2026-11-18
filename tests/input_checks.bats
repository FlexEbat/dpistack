#!/usr/bin/env bats
# Input checks: what a person may type is checked for its meaning, busy ports are
# found while the answers are given, and the tools the menu needs come first.

setup() {
	export DPISTACK_MENU_ASSUME_YES=1
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

run_menu() {
	local input_text="$1" f
	shift
	f="$(mktemp)"
	printf '%b' "$input_text" >"$f"
	run env DPISTACK_INPUT="$f" bash "$REPO_DIR/install.sh" install \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
	rm -f "$f"
}

# entry <key> <value> - schema_validate_entry in a clean shell.
entry() {
	run bash -c 'source "$1/lib/schema.sh"; schema_validate_entry "$2" "$3"' _ "$REPO_DIR" "$1" "$2"
}

@test "an address that cannot exist is refused: octets, prefixes, IPv6" {
	entry HOME_NET "999.999.1.1/99"
	[ "$status" -eq 1 ]
	[[ "$output" == *"999.999.1.1/99 is not an address or a network"* ]]
	entry LAN_CIDR "192.168.0.0/33"
	[ "$status" -eq 1 ]
	entry BIND_ADDR "300.1.1.1"
	[ "$status" -eq 1 ]
	entry HOME_NET "fd00::/129"
	[ "$status" -eq 1 ]
	entry HOME_NET "1:2:3:4:5:6:7:8:9"
	[ "$status" -eq 1 ]
}

@test "real addresses and networks pass, auto too" {
	entry HOME_NET "auto"
	[ "$status" -eq 0 ]
	entry HOME_NET "10.0.0.0/8,192.168.0.0/16,fd00::/8"
	[ "$status" -eq 0 ]
	entry LAN_CIDR "auto,172.16.0.0/12"
	[ "$status" -eq 0 ]
	entry BIND_ADDR "192.168.1.5"
	[ "$status" -eq 0 ]
	entry BIND_ADDR "auto"
	[ "$status" -eq 0 ]
}

@test "EVE_TYPES and ALERT_CHANNELS take only the names the code knows" {
	entry EVE_TYPES "alert,foo"
	[ "$status" -eq 1 ]
	[[ "$output" == *"foo is not a Suricata eve output, allowed: alert"* ]]
	entry EVE_TYPES "alert,flow,dns,tls,http,stats"
	[ "$status" -eq 0 ]
	entry ALERT_CHANNELS "panel,sms"
	[ "$status" -eq 1 ]
	[[ "$output" == *"sms is not an alert channel, allowed: panel log tg mail"* ]]
	entry ALERT_CHANNELS "panel,log,tg"
	[ "$status" -eq 0 ]
}

@test "EVE_REDIS takes no, yes or host[:port][/key]; a bare number or a port out of range is refused" {
	local ok bad
	for ok in "" no yes Yes off 127.0.0.1 127.0.0.1:6379 127.0.0.1:6379/suricata redis.lan:6380/eve; do
		entry EVE_REDIS "$ok"
		[ "$status" -eq 0 ]
	done
	for bad in 10000 127.0.0.1:0 127.0.0.1:70000 127.0.0.1:abc; do
		entry EVE_REDIS "$bad"
		[ "$status" -eq 1 ]
		[[ "$output" == *"use no, yes"* ]]
	done
	entry EVE_REDIS ":6379"
	[ "$status" -eq 1 ]
}

@test "a time that systemd does not accept is refused for the rules update" {
	command -v systemd-analyze >/dev/null || skip "no systemd-analyze here"
	entry RULES_UPDATE_CALENDAR "**:**"
	[ "$status" -eq 1 ]
	entry RULES_UPDATE_CALENDAR "daily"
	[ "$status" -eq 0 ]
	entry RULES_UPDATE_CALENDAR "Mon *-*-* 03:00"
	[ "$status" -eq 0 ]
}

@test "a saved file stays lenient: an unknown eve type loads, an impossible address does not" {
	run bash -c 'source "$1/lib/common.sh"; source "$1/lib/schema.sh"; source "$1/lib/config.sh"; config_load_defaults; CONF[EVE_TYPES]=alert,foo; config_validate; echo "errors=$?"' _ "$REPO_DIR"
	[[ "$output" == *"errors=0"* ]]
	run bash -c 'source "$1/lib/common.sh"; source "$1/lib/schema.sh"; source "$1/lib/config.sh"; config_load_defaults; CONF[HOME_NET]=999.1.1.1/8; config_validate; echo "errors=$?"' _ "$REPO_DIR"
	[[ "$output" == *"999.1.1.1/8 is not an address or a network"* ]]
	[[ "$output" == *"errors=1"* ]]
}

@test "settings check and settings set refuse a value that makes no sense, a saved file is not held to it" {
	local CTL="$REPO_DIR/tests/helpers/verbs"
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'EVE_REDIS=127.0.0.1:6379/eve\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" settings check HOME_NET=300.0.0.0/8
	[ "$status" -eq 3 ]
	[[ "$(jq -r '.errors[0]' <<<"$output")" == *"is not an address or a network"* ]]
	run "$CTL" settings check EVE_TYPES=alert,bogus
	[ "$status" -eq 3 ]
	[[ "$output" == *"bogus is not a Suricata eve output"* ]]
	run "$CTL" settings set EVE_REDIS=10000
	[ "$status" -eq 3 ]
	[[ "$output" == *"use no, yes"* ]]
	run grep -c 'EVE_REDIS=127.0.0.1:6379/eve' "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	[ "$output" = "1" ]
	run "$CTL" settings check STATS_INTERVAL_SEC=45
	[ "$status" -eq 0 ]
}

@test "the menu refuses an interface that is not on this machine and says so at once" {
	run_menu "2\n1\nnosuchif\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"IFACES=nosuchif: there is no interface nosuchif on this machine"* ]]
}

@test "the menu refuses an eve type that does not exist" {
	run_menu "4\n1\nalert,bogus\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bogus is not a Suricata eve output"* ]]
}

@test "the guided setup asks EVE_REDIS, and EVE_MAX_SIZE_MB only when the rotation is by size" {
	run bash -c '
		source "$1/lib/paths.sh"; source "$1/lib/common.sh"; source "$1/lib/schema.sh"; source "$1/lib/key_hints.sh"; source "$1/lib/config.sh"
		source "$1/lib/menu.sh"
		config_load_defaults
		menu_wizard_ask() { echo "ASK $1"; }
		menu_components_screen() { :; }
		menu_confirm() { return 1; }
		menu_draft_save() { :; }
		menu_wizard | sed "s/^/daily /"
		CONF[EVE_ROTATE]=size
		menu_wizard | sed "s/^/size /"
	' _ "$REPO_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"daily ASK EVE_ROTATE"* ]]
	[[ "$output" != *"daily ASK EVE_MAX_SIZE_MB"* ]]
	[[ "$output" == *"size ASK EVE_MAX_SIZE_MB"* ]]
	[[ "$output" == *"daily ASK EVE_REDIS"* ]]
}

@test "a section marks EVE_MAX_SIZE_MB as not used while the rotation is daily" {
	run_menu "4\na\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"EVE_MAX_SIZE_MB"* ]]
	[[ "$output" == *"(not used with the current settings) File size in MB"* ]]
}

@test "a busy port is found before the first screen and the next free one is taken on Enter" {
	MOCK_SS_LISTEN=3000 MOCK_SS_PROC=docker-proxy run_menu "\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING: port 3000 (NTOPNG_PORT) is already busy: docker-proxy"* ]]
	[[ "$output" == *"Another port for NTOPNG_PORT [3001]"* ]]
	[[ "$output" == *"NTOPNG_PORT = 3001"* ]]
	[[ "${output%%WARNING: port 3000*}" != *"Quick install"* ]]
}

@test "a port that is typed in a section is checked as soon as it is typed" {
	MOCK_SS_LISTEN=4000 MOCK_SS_PROC=nginx run_menu "6\na\n5\n4000\n\n0\nq\ny\n"
	[ "$status" -eq 0 ]
	[[ "$output" == *"port 4000 (PANEL_PORT) is already busy: nginx"* ]]
	[[ "$output" == *"Another port for PANEL_PORT [4001]"* ]]
	[[ "$output" == *"PANEL_PORT = 4001"* ]]
}

@test "the panel password step installs jq first, then argon2, when both are missing" {
	local log
	log="$(mktemp)"
	run bash -c '
		source "$1/lib/common.sh"; source "$1/lib/schema.sh"; source "$1/lib/config.sh"; source "$1/lib/menu.sh"
		LOG="$2"
		export PATH=/nonexistent
		pkg_install() { echo "pkg_install $*" >>"$LOG"; }
		die() { echo "died: $*" >>"$LOG"; exit 1; }
		DRY_RUN=0 MENU_PANEL_PASSWORD_SET=1 MENU_PANEL_PASSWORD=secret-pass1
		panel_password_apply
	' _ "$REPO_DIR" "$log"
	[ "$(sed -n 1p "$log")" = "pkg_install jq" ]
	[ "$(sed -n 2p "$log")" = "pkg_install argon2" ]
	rm -f "$log"
}

@test "a failed jq install stops with a message that names jq" {
	local log
	log="$(mktemp)"
	run bash -c '
		source "$1/lib/common.sh"; source "$1/lib/schema.sh"; source "$1/lib/config.sh"; source "$1/lib/menu.sh"
		LOG="$2"
		export PATH=/nonexistent
		pkg_install() { return 1; }
		die() { echo "died: $*" >>"$LOG"; exit 1; }
		DRY_RUN=0 MENU_PANEL_PASSWORD_SET=1 MENU_PANEL_PASSWORD=secret-pass1
		panel_password_apply
	' _ "$REPO_DIR" "$log"
	[ "$status" -eq 1 ]
	[ "$(cat "$log")" = "died: 1 could not install jq" ]
	rm -f "$log"
}
