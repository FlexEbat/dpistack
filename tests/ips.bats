#!/usr/bin/env bats
# Slice 29 (tech.md 17), criteria 1-5 and 7 against stateful iptables mocks.
# Criterion 6 (the panel) is in panel/internal/api/mode_test.go. Not covered:
# a real NFQUEUE, a real reboot and a real rollback timer (tech.md 18.19).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/dpistack-ctl"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0,eth1"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE
	MOCK_CALLS_LOG="$(mktemp)"
	MOCK_IPT_STATE="$(mktemp -u)"
	export MOCK_CALLS_LOG MOCK_IPT_STATE

	# a clock the tests move by hand: the rollback deadline is epoch seconds
	CLOCK_FILE="$(mktemp)"
	echo 1000000 >"$CLOCK_FILE"
	CLOCK_BIN="$(mktemp -d)"
	printf '#!/bin/sh\ncat %s\n' "$CLOCK_FILE" >"$CLOCK_BIN/clock"
	chmod +x "$CLOCK_BIN/clock"
	DPISTACK_NOW_CMD="$CLOCK_BIN/clock"
	export DPISTACK_NOW_CMD

	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	YAML="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	DROPIN="$DPISTACK_ROOT/etc/systemd/system/suricata.service.d/dpistack-mode.conf"
	FWUNIT="$DPISTACK_ROOT/etc/systemd/system/dpistack-fw.service"
	PENDING="$DPISTACK_ROOT/var/lib/dpistack/mode.pending"
	STATE4="$MOCK_IPT_STATE.iptables"
	STATE6="$MOCK_IPT_STATE.ip6tables"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$CLOCK_BIN"
	rm -f "$MOCK_CALLS_LOG" "$CLOCK_FILE" "$STATE4" "$STATE6" "$STATE4.new"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

# A host that is already installed, in ids mode, with someone else's rules.
installed() {
	install_base "$@" >/dev/null 2>&1
	iptables -A INPUT -p tcp --dport 22 -j ACCEPT
	iptables -N MYCHAIN
	iptables -A MYCHAIN -s 10.0.0.0/8 -j DROP
	iptables -A FORWARD -j MYCHAIN
	ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
	: >"$MOCK_CALLS_LOG"
}

advance() { echo $(($(cat "$CLOCK_FILE") + $1)) >"$CLOCK_FILE"; }

@test "criterion 7: SURICATA_MODE=ips is accepted, and its preconditions are checked" {
	run install_base --dry-run --set SURICATA_MODE=ips
	[ "$status" -eq 0 ]
	[[ "$output" != *"пока не поддерживается"* ]]
	run install_base --dry-run --set SURICATA_MODE=ips --set SURICATA_RUNTIME=docker --set NDPI_ENABLE=no
	[ "$status" -eq 2 ]
	[[ "$output" == *"только с SURICATA_RUNTIME=native"* ]]
	run install_base --dry-run --set SURICATA_MODE=ips --set IPS_METHOD=afpacket
	[ "$status" -eq 2 ]
	[[ "$output" == *"чётное число интерфейсов"* ]]
	run install_base --dry-run --set IPS_NFQ_CHAINS=INPUT,FOO
	[ "$status" -eq 2 ]
	[[ "$output" == *"IPS_NFQ_CHAINS"* ]]
}

@test "criteria 1 and 3: mode ips switches Suricata to NFQUEUE and sends traffic to it with --queue-bypass" {
	installed
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	grep -q '^SURICATA_MODE=ips$' "$CONF_FILE"
	# Suricata is started with -q instead of --af-packet, through a drop-in
	grep -q '^ExecStart=.*suricata -c .*suricata.yaml .* -q 0$' "$DROPIN"
	grep -q '^systemctl restart suricata.service' "$MOCK_CALLS_LOG"
	# the DPISTACK chain and one jump per chain of IPS_NFQ_CHAINS, v4 and v6
	for state in "$STATE4" "$STATE6"; do
		grep -qx -- '-N DPISTACK' "$state"
		grep -qx -- '-A DPISTACK -j NFQUEUE --queue-num 0 --queue-bypass' "$state"
		for chain in INPUT OUTPUT FORWARD; do
			grep -qx -- "-A $chain -j DPISTACK" "$state"
		done
		# every NFQUEUE rule has the bypass flag
		[ "$(grep -c -- 'NFQUEUE' "$state")" -eq "$(grep -c -- 'NFQUEUE.*--queue-bypass' "$state")" ]
	done
	# the rollback timer runs
	grep -q -- '^systemd-run --unit=dpistack-mode-rollback --on-active=120s .* mode-rollback$' "$MOCK_CALLS_LOG"
	[ -f "$PENDING" ]
	run "$CTL" mode status --json
	[[ "$output" == '{"mode":"ips","method":"nfq","pending":true,"remaining_sec":120}' ]]
}

@test "criterion 1: IPS_NFQ_CHAINS limits the chains that jump to DPISTACK" {
	installed --set IPS_NFQ_CHAINS=FORWARD
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	grep -qx -- '-A FORWARD -j DPISTACK' "$STATE4"
	if grep -qx -- '-A INPUT -j DPISTACK' "$STATE4"; then false; fi
	! grep -qx -- '-A OUTPUT -j DPISTACK' "$STATE4"
}

@test "criterion 1: a custom --confirm-timeout reaches the timer, out-of-range values are refused" {
	installed
	run "$CTL" mode ips --confirm-timeout 300
	[ "$status" -eq 0 ]
	grep -q -- '--on-active=300s' "$MOCK_CALLS_LOG"
	for bad in 5 99999 abc; do
		run "$CTL" mode ips --confirm-timeout "$bad"
		[ "$status" -eq 2 ]
	done
}

@test "criterion 2: without mode-confirm the rollback returns ids and removes the DPISTACK rules" {
	installed
	"$CTL" mode ips >/dev/null
	: >"$MOCK_CALLS_LOG"
	advance 121
	run "$CTL" mode-rollback
	[ "$status" -eq 0 ]
	grep -q '^SURICATA_MODE=ids$' "$CONF_FILE"
	[ ! -e "$DROPIN" ]
	[ ! -e "$PENDING" ]
	if grep -q 'DPISTACK' "$STATE4" "$STATE6"; then false; fi
	grep -q '^systemctl restart suricata.service' "$MOCK_CALLS_LOG"
	# nothing left to confirm
	run "$CTL" mode-confirm
	[ "$status" -eq 3 ]
}

@test "criterion 2: mode-confirm in time keeps ips, stops the timer and the later rollback does nothing" {
	installed
	"$CTL" mode ips >/dev/null
	advance 60
	run "$CTL" mode-confirm
	[ "$status" -eq 0 ]
	grep -q '^systemctl stop dpistack-mode-rollback.timer' "$MOCK_CALLS_LOG"
	[ ! -e "$PENDING" ]
	advance 600
	run "$CTL" mode-rollback
	[ "$status" -eq 0 ]
	grep -q '^SURICATA_MODE=ips$' "$CONF_FILE"
	grep -qx -- '-A INPUT -j DPISTACK' "$STATE4"
	run "$CTL" mode status --json
	[[ "$output" == '{"mode":"ips","method":"nfq","pending":false,"remaining_sec":0}' ]]
}

@test "criterion 2: a confirmation after the deadline is refused" {
	installed
	"$CTL" mode ips >/dev/null
	advance 121
	run "$CTL" mode-confirm
	[ "$status" -eq 3 ]
	[[ "$output" == *"время подтверждения истекло"* ]]
}

@test "criterion 2: when the rollback timer cannot be started the switch is undone at once" {
	installed
	MOCK_SYSTEMD_RUN_EXIT=1 run "$CTL" mode ips
	[ "$status" -eq 1 ]
	[[ "$output" == *"таймер отката"* ]]
	grep -q '^SURICATA_MODE=ids$' "$CONF_FILE"
	if grep -q 'DPISTACK' "$STATE4"; then false; fi
	[ ! -e "$PENDING" ]
}

@test "criterion 5: foreign chains and rules are not changed, in ips and after the way back" {
	installed
	before=$(iptables-save)
	before6=$(ip6tables-save)
	"$CTL" mode ips >/dev/null
	# while IPS is on, the only difference is DPISTACK and the jumps to it
	[ "$(iptables-save | grep -v DPISTACK)" = "$before" ]
	[ "$(ip6tables-save | grep -v DPISTACK)" = "$before6" ]
	"$CTL" mode-confirm >/dev/null
	"$CTL" mode ids >/dev/null
	[ "$(iptables-save)" = "$before" ]
	[ "$(ip6tables-save)" = "$before6" ]
	# nothing of the other tools' chains was flushed or deleted on the way
	if grep -E '^iptables (-w )?-[FXD] (INPUT|OUTPUT|FORWARD|MYCHAIN)( |$)' "$MOCK_CALLS_LOG" | grep -v 'DPISTACK'; then false; fi
	! grep -qE '^(iptables|ip6tables) (-w )?-F (INPUT|OUTPUT|FORWARD|MYCHAIN)$' "$MOCK_CALLS_LOG"
}

@test "criterion 4: dpistack-fw.service is installed and enabled, and restore puts the rules back" {
	install_base >/dev/null 2>&1
	# enabled, not started: the mode command owns the rules until the next boot
	grep -q '^systemctl enable dpistack-fw.service' "$MOCK_CALLS_LOG"
	if grep -q '^systemctl enable --now dpistack-fw.service' "$MOCK_CALLS_LOG"; then false; fi
	installed
	[ -f "$FWUNIT" ]
	grep -q 'ExecStart=.*dpistack fw restore' "$FWUNIT"
	"$CTL" mode ips >/dev/null
	"$CTL" mode-confirm >/dev/null
	# a reboot empties iptables
	: >"$STATE4"
	: >"$STATE6"
	run "$CTL" fw restore
	[ "$status" -eq 0 ]
	grep -qx -- '-A DPISTACK -j NFQUEUE --queue-num 0 --queue-bypass' "$STATE4"
	grep -qx -- '-A INPUT -j DPISTACK' "$STATE4"
	# the current mode is what comes back: ids leaves nothing
	"$CTL" mode ids >/dev/null
	iptables -N DPISTACK
	iptables -A INPUT -j DPISTACK
	run "$CTL" fw restore
	! grep -q 'DPISTACK' "$STATE4"
}

@test "criterion 4: a reboot before the confirmation is a rollback" {
	installed
	"$CTL" mode ips >/dev/null
	: >"$STATE4"
	run "$CTL" fw restore
	[ "$status" -eq 0 ]
	grep -q '^SURICATA_MODE=ids$' "$CONF_FILE"
	[ ! -e "$PENDING" ]
	! grep -q 'DPISTACK' "$STATE4"
}

@test "IPS over af-packet: interfaces are paired in copy-mode, no iptables and no drop-in" {
	installed --set IFACES=enp2s0,eth1 --set IPS_METHOD=afpacket
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	grep -q '^    copy-mode: ips$' "$YAML"
	grep -A5 '^  - interface: enp2s0' "$YAML" | grep -q '^    copy-iface: eth1$'
	grep -A5 '^  - interface: eth1' "$YAML" | grep -q '^    copy-iface: enp2s0$'
	[ ! -e "$DROPIN" ]
	if grep -q '^iptables ' "$MOCK_CALLS_LOG"; then false; fi
	"$CTL" mode ids >/dev/null
	! grep -q '^    copy-mode: ips$' "$YAML"
}

@test "mode ips is refused without what it needs, and nothing is changed" {
	installed
	PATH="$(echo "$PATH" | tr ':' '\n' | grep -v 'tests/mocks' | paste -sd:)" run "$CTL" mode ips
	[ "$status" -ne 0 ]
	grep -q '^SURICATA_MODE=ids$' "$CONF_FILE"
	run "$CTL" mode bogus
	[ "$status" -eq 2 ]
}

@test "a repeat install in ips mode changes nothing, uninstall removes the chain, the unit and the drop-in" {
	installed --set SURICATA_MODE=ips
	: >"$MOCK_CALLS_LOG"
	run install_base --set SURICATA_MODE=ips
	[ "$status" -eq 0 ]
	if grep -q '^systemctl restart suricata.service' "$MOCK_CALLS_LOG"; then false; fi
	before=$(iptables-save | grep -v DPISTACK)
	"$CTL" fw apply
	grep -qx -- '-N DPISTACK' "$STATE4"
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	if grep -q 'DPISTACK' "$STATE4" "$STATE6"; then false; fi
	[ ! -e "$FWUNIT" ]
	[ ! -e "$DROPIN" ]
	[ "$(iptables-save)" = "$before" ]
}

@test "NFQ drop-in: no --user when the log directory is not owned by suricata, --user when it is" {
	installed
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	[ "$(grep -c -- '--user' "$DROPIN")" -eq 0 ]
	DPISTACK_TEST_LOG_OWNER=suricata run "$CTL" reconfigure
	run "$CTL" mode ids
	DPISTACK_TEST_LOG_OWNER=suricata run "$CTL" mode ips
	[ "$status" -eq 0 ]
	grep -q -- ' -q 0 --user suricata --group suricata$' "$DROPIN"
}

@test "mode ips warns when nothing can drop, and stays quiet when a drop rule or drop.conf line exists" {
	installed
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	[[ "$output" == *"правил drop нет"* ]]
	run "$CTL" mode ids
	mkdir -p "$DPISTACK_ROOT/etc/suricata/rules"
	echo 'drop tcp any any -> any 8080 (msg:"x"; sid:1000001; rev:1;)' >"$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	[[ "$output" != *"правил drop нет"* ]]
	run "$CTL" mode ids
	: >"$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	echo 'group:emerging-p2p.rules' >"$DPISTACK_ROOT/etc/suricata/drop.conf"
	run "$CTL" mode ips
	[[ "$output" != *"правил drop нет"* ]]
}

@test "a failed rollback service is reset before the next timer is started, so the unit name is free" {
	installed
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	grep -q '^systemctl reset-failed dpistack-mode-rollback.timer dpistack-mode-rollback.service' "$MOCK_CALLS_LOG"
	reset=$(grep -n 'systemctl reset-failed dpistack-mode-rollback' "$MOCK_CALLS_LOG" | head -1 | cut -d: -f1)
	run_line=$(grep -n '^systemd-run --unit=dpistack-mode-rollback' "$MOCK_CALLS_LOG" | head -1 | cut -d: -f1)
	[ "$reset" -lt "$run_line" ]
}

# A host with nft and no iptables (a minimal Rocky or Alma): the mocks
# without iptables and ip6tables, and no real one in the path either.
nft_only_path() {
	NFT_ONLY_BIN="$(mktemp -d)"
	local m
	for m in "$REPO_DIR"/tests/mocks/*; do
		case "$(basename "$m")" in iptables | ip6tables | iptables-save | ip6tables-save) ;; *) ln -s "$m" "$NFT_ONLY_BIN/" ;; esac
	done
	echo "$NFT_ONLY_BIN:/usr/bin:/bin"
}

@test "IPS without iptables: mode ips puts the queue into its own nft table, mode ids takes it out" {
	installed
	NFTPATH="$(nft_only_path)"
	NFTSTATE="$MOCK_IPT_STATE.nft"
	PATH="$NFTPATH" run "$CTL" mode ips
	[ "$status" -eq 0 ]
	# one table of its own, one base chain per hook, each queueing with bypass
	grep -qx 'table inet dpistack {' "$NFTSTATE"
	for hook in input output forward; do
		grep -q "chain $hook {" "$NFTSTATE"
		grep -q "type filter hook $hook priority -10; policy accept;" "$NFTSTATE"
	done
	[ "$(grep -c 'queue num 0 bypass' "$NFTSTATE")" -eq 3 ]
	# nothing went to iptables and the host's own rules are as they were
	if grep -q '^iptables' "$MOCK_CALLS_LOG"; then false; fi
	grep -qx -- '-A INPUT -p tcp --dport 22 -j ACCEPT' "$STATE4"
	PATH="$NFTPATH" run "$CTL" mode ids
	[ "$status" -eq 0 ]
	[ ! -e "$NFTSTATE" ]
	rm -rf "$NFT_ONLY_BIN" "$NFTSTATE"
}

@test "IPS without iptables: IPS_NFQ_CHAINS limits the hooks, fw remove and uninstall delete the table" {
	installed --set IPS_NFQ_CHAINS=FORWARD
	NFTPATH="$(nft_only_path)"
	NFTSTATE="$MOCK_IPT_STATE.nft"
	PATH="$NFTPATH" run "$CTL" mode ips
	[ "$status" -eq 0 ]
	grep -q 'chain forward {' "$NFTSTATE"
	if grep -q 'chain input {' "$NFTSTATE"; then false; fi
	PATH="$NFTPATH" "$CTL" fw remove
	[ ! -e "$NFTSTATE" ]
	PATH="$NFTPATH" "$CTL" fw apply
	[ -s "$NFTSTATE" ]
	PATH="$NFTPATH" run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$NFTSTATE" ]
	rm -rf "$NFT_ONLY_BIN" "$NFTSTATE"
}

@test "IPS: when iptables is there a leftover nft table is removed, packets are never queued twice" {
	installed
	NFTSTATE="$MOCK_IPT_STATE.nft"
	printf 'table inet dpistack {\n}\n' >"$NFTSTATE"
	run "$CTL" mode ips
	[ "$status" -eq 0 ]
	[ ! -e "$NFTSTATE" ]
	grep -qx -- '-A INPUT -j DPISTACK' "$STATE4"
}

@test "IPS: the refusal names both tools, and without either nothing is changed" {
	installed
	EMPTY_BIN="$(mktemp -d)"
	for m in "$REPO_DIR"/tests/mocks/*; do
		case "$(basename "$m")" in iptables | ip6tables | iptables-save | ip6tables-save | nft) ;; *) ln -s "$m" "$EMPTY_BIN/" ;; esac
	done
	PATH="$EMPTY_BIN:/usr/bin:/bin" run "$CTL" mode ips
	[ "$status" -eq 3 ]
	[[ "$output" == *"ни iptables, ни nft"* ]]
	grep -q '^SURICATA_MODE=ids$' "$CONF_FILE"
	rm -rf "$EMPTY_BIN"
}
