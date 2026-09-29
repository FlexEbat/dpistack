#!/usr/bin/env bats
# Covers slice 7 criteria 1, 3, 5, 6 (per tech.md's own test scope).

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
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	MOCK_IP_LINK_ROUTE="192.168.10.0/24"
	export MOCK_IP_DEFAULT_IFACE MOCK_IP_LINK_ROUTE
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	NGINX_CONFD="$DPISTACK_ROOT/etc/nginx/conf.d/dpistack.conf"
	NGINX_SNIPPET="$DPISTACK_ROOT/var/lib/dpistack/nginx/dpistack.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "criterion 1: ACCESS_MODE=localhost keeps ntopng and evebox on 127.0.0.1" {
	run install_base
	[ "$status" -eq 0 ]
	grep -q '^-w=127.0.0.1:3000$' "$DPISTACK_ROOT/etc/ntopng/ntopng.conf"
	grep -q '^  host: "127.0.0.1"$' "$DPISTACK_ROOT/etc/evebox/evebox.yaml"
}

@test "criterion 1: ACCESS_MODE=lan (confirmed) binds ntopng/evebox to 0.0.0.0" {
	run install_base --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -q '^-w=0.0.0.0:3000$' "$DPISTACK_ROOT/etc/ntopng/ntopng.conf"
	grep -q '^  host: "0.0.0.0"$' "$DPISTACK_ROOT/etc/evebox/evebox.yaml"
	[[ "$output" == *"видны всей сети"* ]]
}

@test "criterion 3: nginx+snippet never touches nginx.conf or reloads nginx" {
	run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	[ -f "$NGINX_SNIPPET" ]
	[ ! -e "$NGINX_CONFD" ]
	run grep -c "systemctl.*nginx" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
}

@test "criterion 3 (contrast): nginx+yes does write conf.d and reloads nginx" {
	run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=yes --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	[ -f "$NGINX_CONFD" ]
	run grep -c "systemctl enable --now nginx.service" "$MOCK_CALLS_LOG"
	[ "$output" = "1" ]
}

@test "criterion 5: NGINX_TLS=existing without cert/key exits 2" {
	run install_base --set ACCESS_MODE=nginx --set ACCESS_CONFIRM=yes --set NGINX_TLS=existing
	[ "$status" -eq 2 ]
	[[ "$output" == *"NGINX_CERT"* ]]
}

@test "criterion 5: NGINX_TLS=existing with both cert and key passes validation" {
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set ACCESS_MODE=nginx --set ACCESS_CONFIRM=yes \
		--set NGINX_TLS=existing --set NGINX_CERT=/tmp/c.pem --set NGINX_KEY=/tmp/k.pem
	[ "$status" -eq 0 ]
}

@test "criterion 6: ACCESS_MODE=lan without ACCESS_CONFIRM exits 2 and changes nothing" {
	run install_base --set ACCESS_MODE=lan
	[ "$status" -eq 2 ]
	[[ "$output" == *"ACCESS_CONFIRM"* ]]
	[ ! -e "$DPISTACK_ROOT/etc/ntopng/ntopng.conf" ]
}

@test "criterion 4: a real nginx -t passes on the rendered config (isolated dir)" {
	command -v /usr/sbin/nginx >/dev/null 2>&1 || skip "real nginx not installed in this environment"

	run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=yes --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	[ -f "$NGINX_CONFD" ]

	# tests/mocks/nginx shadows the real binary for everything else in
	# this suite; reach past it here so this test means something.
	run env PATH="/usr/sbin:/usr/bin:$PATH" bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/state.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/render.sh"
		source "'"$REPO_DIR"'/lib/step_access.sh"
		/usr/sbin/nginx -t -c /dev/null >/dev/null 2>&1
		access_nginx_test_ok && echo REAL_NGINX_T_OK
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"REAL_NGINX_T_OK"* ]]
}
