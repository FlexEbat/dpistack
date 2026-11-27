#!/usr/bin/env bats
# ACCESS_MODE=caddy (task 67): Caddy as the other reverse proxy, run as its
# own service, with a certificate it looks after itself.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	REAL_CADDY="$(command -v caddy || true)"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	export MOCK_CALLS_LOG
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	E="$DPISTACK_ROOT/etc"
	mkdir -p "$E"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	CF="$E/dpistack/Caddyfile"
	UNIT="$E/systemd/system/dpistack-caddy.service"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no "$@"
}

install_caddy() {
	install_base --set ACCESS_MODE=caddy --set ACCESS_CONFIRM=yes "$@"
}

@test "caddy mode: one site per service on the public port, proxied to the port plus 10000, with the local CA" {
	run install_caddy --set LAN_CIDR=192.168.1.0/24
	[ "$status" -eq 0 ]
	[ -f "$CF" ]
	grep -q '^# ntopng$' "$CF"
	grep -q '^# evebox$' "$CF"
	grep -q '^# panel$' "$CF"
	grep -q 'https://localhost:3000' "$CF"
	grep -q 'https://localhost:5636' "$CF"
	grep -q 'https://localhost:9800' "$CF"
	grep -q 'reverse_proxy 127.0.0.1:13000' "$CF"
	grep -q 'reverse_proxy 127.0.0.1:15636' "$CF"
	grep -q 'reverse_proxy 127.0.0.1:19800' "$CF"
	[ "$(grep -c '^	tls internal$' "$CF")" -eq 3 ]
	[ "$(grep -c 'remote_ip 192.168.1.0/24$' "$CF")" -eq 3 ]
	grep -q 'respond 403' "$CF"
	grep -q '^	admin off$' "$CF"
}

@test "caddy mode: the unit is its own service with a transient user, and the host's Caddy is not touched" {
	run install_caddy
	[ "$status" -eq 0 ]
	grep -q '^ExecStart=.* run --environ --config '"$CF"' --adapter caddyfile$' "$UNIT"
	grep -q '^DynamicUser=yes$' "$UNIT"
	grep -q '^StateDirectory=dpistack-caddy$' "$UNIT"
	grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE$' "$UNIT"
	grep -q '^systemctl enable dpistack-caddy.service' "$MOCK_CALLS_LOG"
	grep -q '^systemctl restart dpistack-caddy.service' "$MOCK_CALLS_LOG"
	[ ! -e "$E/caddy/Caddyfile" ]
	! grep -q 'enable --now caddy.service' "$MOCK_CALLS_LOG"
}

@test "caddy mode: no certificate is asked for or made: no nginx files, no panel certificate, no flag" {
	run install_caddy
	[ "$status" -eq 0 ]
	[ ! -e "$E/dpistack/tls" ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack/nginx" ]
	run cat "$E/systemd/system/dpistack-panel.service"
	[[ "$output" != *"-tls-cert"* ]]
	[[ "$output" == *"-access nginx"* ]]
}

@test "caddy mode: CADDY_DOMAIN asks for a public certificate: the domain is the site, there is no local CA" {
	run install_caddy --set CADDY_DOMAIN=dpi.example.org
	[ "$status" -eq 0 ]
	grep -q '^https://dpi.example.org:3000 {$' "$CF"
	grep -q '^https://dpi.example.org:9800 {$' "$CF"
	[ "$(grep -c 'tls internal' "$CF")" -eq 0 ]
	[[ "$output" == *"ports 80 and 443 must reach this host"* ]]
}

@test "caddy mode: the domain is checked" {
	run install_caddy --dry-run --set 'CADDY_DOMAIN=bad domain'
	[ "$status" -ne 0 ]
	run install_caddy --dry-run --set 'CADDY_DOMAIN=a;b'
	[ "$status" -ne 0 ]
}

@test "caddy mode: a second apply changes nothing" {
	install_caddy
	run install_caddy
	[ "$status" -eq 0 ]
	[[ "$output" == *"access ... no changes"* ]]
}

@test "caddy mode: a Caddyfile that caddy validate refuses is not put in place" {
	mkdir -p "$DPISTACK_ROOT/badbin"
	printf '#!/usr/bin/env bash\n[[ "$1" == validate ]] && exit 1\nexit 0\n' >"$DPISTACK_ROOT/badbin/caddy"
	chmod +x "$DPISTACK_ROOT/badbin/caddy"
	run env PATH="$DPISTACK_ROOT/badbin:$PATH" bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no --set ACCESS_MODE=caddy --set ACCESS_CONFIRM=yes
	[ "$status" -ne 0 ]
	[[ "$output" == *"caddy validate failed"* ]]
	[ ! -e "$CF" ]
}

@test "caddy mode: the rendered Caddyfile is valid for a real Caddy" {
	[ -n "$REAL_CADDY" ] || skip "caddy is not installed"
	run install_caddy --set LAN_CIDR=10.0.0.0/8,192.168.0.0/16
	[ "$status" -eq 0 ]
	run "$REAL_CADDY" validate --config "$CF" --adapter caddyfile
	[ "$status" -eq 0 ]
	rm -rf "$E/dpistack" "$DPISTACK_ROOT/var"
	run install_caddy --set CADDY_DOMAIN=dpi.example.org
	[ "$status" -eq 0 ]
	run "$REAL_CADDY" validate --config "$CF" --adapter caddyfile
	[ "$status" -eq 0 ]
}

@test "caddy mode: the sample caddy.service of a fresh package is stopped, a configured one is left alone" {
	run install_caddy
	[ "$status" -eq 0 ]
	grep -q '^systemctl disable --now caddy.service' "$MOCK_CALLS_LOG"
	: >"$MOCK_CALLS_LOG"
	rm -rf "$E/dpistack" "$DPISTACK_ROOT/var"
	mkdir -p "$E/caddy"
	printf 'example.org {\n\trespond hello\n}\n' >"$E/caddy/Caddyfile"
	run install_caddy
	[ "$status" -eq 0 ]
	! grep -q 'disable --now caddy.service' "$MOCK_CALLS_LOG"
}

@test "caddy mode: the ports are limited like nginx's, and the message names the mode" {
	run install_caddy --dry-run --set NTOPNG_PORT=60000
	[ "$status" -ne 0 ]
	[[ "$output" == *"ACCESS_MODE=caddy needs NTOPNG_PORT not above 55535"* ]]
}

@test "caddy mode: the firewall opens the public ports for LAN_CIDR like nginx" {
	run install_caddy --set FIREWALL_MANAGE=auto --set LAN_CIDR=192.168.1.0/24
	[ "$status" -eq 0 ]
	grep -q 'ufw allow from 192.168.1.0/24 to any port 3000 proto tcp' "$MOCK_CALLS_LOG"
	grep -q 'ufw allow from 192.168.1.0/24 to any port 9800 proto tcp' "$MOCK_CALLS_LOG"
}

@test "caddy mode: tls show names the root of the local CA with its fingerprint, renew and import leave it to Caddy" {
	install_caddy
	run "$CTL" tls show
	[ "$status" -eq 0 ]
	[[ "$output" == *"caddy-local-ca (caddy-local-ca)"* ]]
	[[ "$output" == *"not found or not readable"* ]]
	mkdir -p "$DPISTACK_ROOT/var/lib/dpistack-caddy/caddy/pki/authorities/local"
	openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 90 \
		-keyout "$DPISTACK_ROOT/k" -out "$DPISTACK_ROOT/var/lib/dpistack-caddy/caddy/pki/authorities/local/root.crt" -subj "/CN=root" 2>/dev/null
	want=$(openssl x509 -in "$DPISTACK_ROOT/var/lib/dpistack-caddy/caddy/pki/authorities/local/root.crt" -noout -fingerprint -sha256)
	run "$CTL" tls show
	[[ "$output" == *"SHA-256 ${want#*=}"* ]]
	[[ "$output" == *"trust it once in the browser"* ]]
	run "$CTL" tls renew --force
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to renew"* ]]
	run "$CTL" tls import "$DPISTACK_ROOT/k" "$DPISTACK_ROOT/k"
	[ "$status" -eq 3 ]
	[[ "$output" == *"Caddy looks after the certificate"* ]]
}

@test "caddy mode: info says https for all three and the security screen names Caddy" {
	install_caddy
	run "$CTL" info --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '[.screens[] | .url | .[0:8]] | unique | .[]' <<<"$output")" = "https://" ]
	run "$CTL" security check --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.checks[] | select(.id=="access-mode") | .level' <<<"$output")" = "ok" ]
	[[ "$(jq -r '.checks[] | select(.id=="tls") | .detail' <<<"$output")" == *"Caddy serves the panel over TLS"* ]]
}

@test "caddy mode: uninstall removes the unit and keeps the Caddyfile and the state of the local CA" {
	install_caddy
	mkdir -p "$DPISTACK_ROOT/var/lib/dpistack-caddy/caddy"
	run bash "$REPO_DIR/install.sh" uninstall -y
	[ "$status" -eq 0 ]
	[ ! -e "$UNIT" ]
	grep -q '^systemctl disable --now dpistack-caddy.service' "$MOCK_CALLS_LOG"
	[ -e "$CF" ]
	[ -d "$DPISTACK_ROOT/var/lib/dpistack-caddy" ]
}

@test "caddy mode: uninstall --purge also removes the Caddyfile and the state of the local CA" {
	install_caddy
	mkdir -p "$DPISTACK_ROOT/var/lib/dpistack-caddy/caddy"
	run bash "$REPO_DIR/install.sh" uninstall -y --purge
	[ "$status" -eq 0 ]
	[ ! -e "$UNIT" ]
	[ ! -e "$CF" ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack-caddy" ]
}

@test "switching from caddy back to localhost gives the panel its own certificate again" {
	install_caddy
	run install_base --set ACCESS_MODE=localhost
	[ "$status" -eq 0 ]
	run cat "$E/systemd/system/dpistack-panel.service"
	[[ "$output" == *"-tls-cert"* ]]
}
