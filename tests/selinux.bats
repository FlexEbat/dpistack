#!/usr/bin/env bats
# Slice 26 criteria 2 and 3: SELinux labels and ports, and firewalld rules
# for LAN_CIDR only. Mocks only (getenforce, semanage, restorecon,
# firewall-cmd): no AVC denial was observed on a real Enforcing host, see
# tech.md 18.16.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=rocky\nID_LIKE="rhel centos fedora"\nVERSION_ID="9.4"\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	MOCK_IP_LINK_ROUTE="192.168.10.0/24"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE MOCK_IP_LINK_ROUTE
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

# fam <script> - libs loaded and the OS detected, no ufw on this host.
fam() {
	bash -c "
		cd '$REPO_DIR'
		source lib/paths.sh; source lib/common.sh; source lib/state.sh; source lib/os.sh
		for f in lib/step_*.sh; do source \$f; done
		declare -A CONF=()
		os_detect >/dev/null 2>&1
		command() { if [[ \"\$1\" == '-v' && \"\$2\" == 'ufw' ]]; then return 1; else builtin command \"\$@\"; fi; }
		$1" 2>&1
}

@test "criterion 2: nginx mode gives the public ports http_port_t and the ntopng backend ntop_port_t" {
	MOCK_GETENFORCE=Enforcing run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	for port in 3000 5636 9800; do
		grep -qx "semanage port -a -t http_port_t -p tcp $port" "$MOCK_CALLS_LOG"
	done
	grep -qx "semanage port -a -t ntop_port_t -p tcp 13000" "$MOCK_CALLS_LOG"
	grep -qx "setsebool -P httpd_can_network_connect 1" "$MOCK_CALLS_LOG"
}

@test "criterion 2: localhost mode on default ports labels no port" {
	MOCK_GETENFORCE=Enforcing run install_base
	[ "$status" -eq 0 ]
	! grep -q '^semanage port -[am]' "$MOCK_CALLS_LOG"
}

@test "criterion 2: a port that already has the type is not touched again" {
	MOCK_SEMANAGE_LIST="http_port_t tcp 80, 81, 9800, 443" MOCK_GETENFORCE=Enforcing \
		run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	! grep -qx "semanage port -a -t http_port_t -p tcp 9800" "$MOCK_CALLS_LOG"
	grep -qx "semanage port -a -t http_port_t -p tcp 3000" "$MOCK_CALLS_LOG"
}

@test "criterion 2: a port the policy already defines is remapped with -m" {
	MOCK_SEMANAGE_ADD_EXIT=1 MOCK_GETENFORCE=Enforcing \
		run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -qx "semanage port -m -t http_port_t -p tcp 3000" "$MOCK_CALLS_LOG"
}

@test "criterion 2: a type the policy lacks is a warning, not a failed install" {
	MOCK_SEMANAGE_ADD_EXIT=1 MOCK_SEMANAGE_MOD_EXIT=1 MOCK_GETENFORCE=Enforcing \
		run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"не удалось дать порту"* ]]
}

@test "criterion 2: with SELinux disabled nothing is labeled" {
	MOCK_GETENFORCE=Disabled run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	! grep -q '^semanage' "$MOCK_CALLS_LOG"
	! grep -q '^restorecon' "$MOCK_CALLS_LOG"
}

@test "criterion 2: the end of install restores labels on the paths that exist" {
	MOCK_GETENFORCE=Enforcing run install_base
	[ "$status" -eq 0 ]
	line=$(grep '^restorecon -RF' "$MOCK_CALLS_LOG" | head -1)
	[[ "$line" == *"$DPISTACK_ROOT/etc/dpistack"* ]]
	[[ "$line" == *"$DPISTACK_ROOT/var/lib/dpistack"* ]]
	[[ "$line" == *"$DPISTACK_ROOT/etc/suricata"* ]]
	# a path that was never created is not passed to restorecon
	[[ "$line" != *"$DPISTACK_ROOT/etc/nginx/conf.d"* ]]
}

@test "criterion 2: a dry run labels nothing" {
	MOCK_GETENFORCE=Enforcing run install_base --dry-run --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	! grep -q '^semanage port -[am]' "$MOCK_CALLS_LOG"
	! grep -q '^restorecon' "$MOCK_CALLS_LOG"
}

@test "criterion 2: every file the installer writes gets its policy label (atomic_write)" {
	target="$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	MOCK_GETENFORCE=Enforcing run fam "echo x | atomic_write '$target'"
	[ "$status" -eq 0 ]
	grep -qx "restorecon -F $target" "$MOCK_CALLS_LOG"
	: >"$MOCK_CALLS_LOG"
	MOCK_GETENFORCE=Disabled run fam "echo x | atomic_write '$target'"
	! grep -q '^restorecon' "$MOCK_CALLS_LOG"
}

@test "criterion 3: FIREWALL_MANAGE=auto opens each port for LAN_CIDR only, through firewalld" {
	run fam 'CONF[ACCESS_MODE]=lan; CONF[FIREWALL_MANAGE]=auto; CONF[LAN_CIDR]=192.168.10.0/24; access_firewall_apply'
	[ "$status" -eq 0 ]
	for port in 3000 5636 9800; do
		grep -qx "firewall-cmd --permanent --add-rich-rule=rule family=ipv4 source address=192.168.10.0/24 port port=$port protocol=tcp accept" "$MOCK_CALLS_LOG"
	done
	# no rule without a source address, nothing opens to the world
	[ "$(grep -c -- '--add-rich-rule' "$MOCK_CALLS_LOG")" -eq 3 ]
	! grep -- '--add-rich-rule' "$MOCK_CALLS_LOG" | grep -v 'source address=192.168.10.0/24'
	grep -qx 'firewall-cmd --reload' "$MOCK_CALLS_LOG"
}

@test "criterion 3: localhost mode and FIREWALL_MANAGE=no open nothing" {
	run fam 'CONF[ACCESS_MODE]=localhost; CONF[FIREWALL_MANAGE]=auto; CONF[LAN_CIDR]=192.168.10.0/24; access_firewall_apply'
	! grep -q -- '--add-rich-rule' "$MOCK_CALLS_LOG"
	run fam 'CONF[ACCESS_MODE]=lan; CONF[FIREWALL_MANAGE]=no; access_firewall_apply'
	! grep -q -- '--add-rich-rule' "$MOCK_CALLS_LOG"
}

@test "criterion 3: a stopped firewalld gets no rules and a message, the install goes on" {
	MOCK_FIREWALLD_STATE_EXIT=1 run fam 'CONF[ACCESS_MODE]=lan; CONF[FIREWALL_MANAGE]=auto; CONF[LAN_CIDR]=192.168.10.0/24; access_firewall_apply'
	[ "$status" -eq 0 ]
	[[ "$output" == *"firewalld не запущен"* ]]
	! grep -q -- '--add-rich-rule' "$MOCK_CALLS_LOG"
	! grep -q -- '--reload' "$MOCK_CALLS_LOG"
}
