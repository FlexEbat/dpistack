#!/usr/bin/env bats
# ufw and firewalld rules of ACCESS_MODE: dpistack takes out the rules it
# added when the mode, LAN_CIDR or FIREWALL_MANAGE no longer want them, and
# on uninstall - and never a rule the administrator had. Against stateful
# ufw and firewall-cmd mocks (tests/mocks); a real ufw or firewalld is not
# in the sandbox (tech.md 18.21).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	UFW_RULES="$MOCK_CALLS_LOG.ufw"
	FWD_RULES="$MOCK_CALLS_LOG.fwd"
	STATE="$DPISTACK_ROOT/var/lib/dpistack/state"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG" "$UFW_RULES" "$FWD_RULES" "$UFW_RULES.new" "$FWD_RULES.new"
}

install_lan() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes --set LAN_CIDR=10.1.0.0/24 \
		--set FIREWALL_MANAGE=auto "$@"
}

@test "ufw: leaving lan mode takes our rules out, the administrator's own rule stays" {
	# the administrator already allows the panel port for the same network
	ufw allow from 10.1.0.0/24 to any port 9800 proto tcp
	run install_lan
	[ "$status" -eq 0 ]
	grep -qxF 'ufw allow from 10.1.0.0/24 to any port 3000 proto tcp' "$UFW_RULES"
	grep -qxF 'ufw allow from 10.1.0.0/24 to any port 5636 proto tcp' "$UFW_RULES"
	# the rule that was there before is not written down as ours
	grep -q '^access.fw.rules=.*10.1.0.0/24,3000' "$STATE"
	if grep '^access.fw.rules=' "$STATE" | grep -q ',9800'; then false; fi
	run bash "$REPO_DIR/install.sh" reconfigure -y --force --set ACCESS_MODE=localhost
	[ "$status" -eq 0 ]
	if grep -q 'port 3000\|port 5636' "$UFW_RULES"; then false; fi
	grep -qxF 'ufw allow from 10.1.0.0/24 to any port 9800 proto tcp' "$UFW_RULES"
	grep -q '^ufw --force delete allow from 10.1.0.0/24 to any port 3000 proto tcp$' "$MOCK_CALLS_LOG"
}

@test "ufw: a changed LAN_CIDR moves the rules, FIREWALL_MANAGE=no takes them all out" {
	run install_lan
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" reconfigure -y --force --set ACCESS_CONFIRM=yes --set LAN_CIDR=10.2.0.0/24
	[ "$status" -eq 0 ]
	grep -qxF 'ufw allow from 10.2.0.0/24 to any port 3000 proto tcp' "$UFW_RULES"
	if grep -q '10.1.0.0/24' "$UFW_RULES"; then false; fi
	run bash "$REPO_DIR/install.sh" reconfigure -y --force --set ACCESS_CONFIRM=yes --set FIREWALL_MANAGE=no
	[ "$status" -eq 0 ]
	[ "$(grep -c '^ufw allow' "$UFW_RULES")" -eq 0 ]
}

@test "ufw: uninstall takes out the rules dpistack added and no others" {
	ufw allow from 192.168.0.0/16 to any port 22 proto tcp
	run install_lan
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ "$(grep -c '^ufw allow' "$UFW_RULES")" -eq 1 ]
	grep -qxF 'ufw allow from 192.168.0.0/16 to any port 22 proto tcp' "$UFW_RULES"
}

@test "ufw: a repeat reconfigure adds nothing twice" {
	run install_lan
	[ "$status" -eq 0 ]
	before=$(sort "$UFW_RULES")
	run bash "$REPO_DIR/install.sh" reconfigure -y --force --set ACCESS_CONFIRM=yes --set EVEBOX_PORT=5640
	[ "$status" -eq 0 ]
	grep -qxF 'ufw allow from 10.1.0.0/24 to any port 5640 proto tcp' "$UFW_RULES"
	if grep -q 'port 5636' "$UFW_RULES"; then false; fi
	[ "$(grep -c 'port 3000 ' "$UFW_RULES")" -eq 1 ]
	[ -n "$before" ]
}

# firewalld: ufw is not on the path, firewall-cmd is, and --reload follows.
fwd_path() {
	FWD_BIN="$(mktemp -d)"
	local m
	for m in "$REPO_DIR"/tests/mocks/*; do
		[[ "$(basename "$m")" == ufw ]] || ln -s "$m" "$FWD_BIN/"
	done
	echo "$FWD_BIN:/usr/bin:/bin"
}

@test "firewalld: leaving lan mode removes our rich rules and reloads, uninstall removes the rest" {
	FWPATH="$(fwd_path)"
	rule='rule family=ipv4 source address=10.1.0.0/24 port port=%s protocol=tcp accept'
	PATH="$FWPATH" run install_lan
	[ "$status" -eq 0 ]
	for p in 3000 5636 9800; do grep -qxF "$(printf "$rule" "$p")" "$FWD_RULES"; done
	PATH="$FWPATH" run bash "$REPO_DIR/install.sh" reconfigure -y --force --set ACCESS_MODE=localhost
	[ "$status" -eq 0 ]
	[ "$(grep -c . "$FWD_RULES")" -eq 0 ]
	grep -q -- "^firewall-cmd --permanent --remove-rich-rule=$(printf "$rule" 3000)\$" "$MOCK_CALLS_LOG"
	: >"$MOCK_CALLS_LOG"
	PATH="$FWPATH" run bash "$REPO_DIR/install.sh" reconfigure -y --force --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	PATH="$FWPATH" run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ "$(grep -c . "$FWD_RULES")" -eq 0 ]
	grep -qx 'firewall-cmd --reload' "$MOCK_CALLS_LOG"
	rm -rf "$FWD_BIN"
}

@test "uninstall restarts Suricata that was started in IPS mode, and only then" {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set SURICATA_MODE=ips >/dev/null 2>&1
	DROPIN="$DPISTACK_ROOT/etc/systemd/system/suricata.service.d/dpistack-mode.conf"
	[ -e "$DROPIN" ]
	: >"$MOCK_CALLS_LOG"
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$DROPIN" ]
	# the restart comes after the drop-in is gone and systemd has re-read units
	grep -n '^systemctl' "$MOCK_CALLS_LOG" | grep -A3 'daemon-reload' | grep -q 'restart suricata.service'
	# an ids install is not restarted by uninstall
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	: >"$MOCK_CALLS_LOG"
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	if grep -q '^systemctl restart suricata.service' "$MOCK_CALLS_LOG"; then false; fi
}
