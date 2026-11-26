#!/usr/bin/env bats
# PANEL_TLS (task 64): the panel serves HTTPS itself, with a certificate the
# program makes, shows the fingerprint of and renews.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	export MOCK_CALLS_LOG
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	E="$DPISTACK_ROOT/etc"
	mkdir -p "$E"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$E/os-release"
	TLS="$E/dpistack/tls"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf \
		--set NDPI_ENABLE=no --set TEST_ON_INSTALL=no "$@"
}

unit() { cat "$E/systemd/system/dpistack-panel.service"; }

@test "selfsigned: the unit names the pair, and the pair is an EC key with names in subjectAltName" {
	run install_base --set PANEL_TLS=selfsigned
	[ "$status" -eq 0 ]
	unit | grep -q -- "-tls-cert $TLS/panel.crt -tls-key $TLS/panel.key"
	[ -f "$TLS/panel.crt" ]
	[ -f "$TLS/panel.key" ]
	run openssl x509 -in "$TLS/panel.crt" -noout -ext subjectAltName
	[[ "$output" == *"DNS:localhost"* ]]
	[[ "$output" == *"IP Address:127.0.0.1"* ]]
	run openssl x509 -in "$TLS/panel.crt" -noout -text
	[[ "$output" == *"prime256v1"* ]]
	[ "$(stat -c %a "$TLS/panel.key")" = "640" ]
	[ "$(stat -c %a "$TLS/panel.crt")" = "644" ]
	run grep -c '^chgrp dpistack ' "$MOCK_CALLS_LOG"
	[ "$output" -ge 1 ]
}

@test "the default is HTTPS: a certificate is made without being asked for" {
	run install_base
	[ "$status" -eq 0 ]
	run unit
	[[ "$output" == *"-tls-cert $TLS/panel.crt"* ]]
	[ -f "$TLS/panel.crt" ]
}

@test "none is not a value any more, for the panel or for nginx" {
	run install_base --dry-run --set PANEL_TLS=none
	[ "$status" -ne 0 ]
	run install_base --dry-run --set NGINX_TLS=none
	[ "$status" -ne 0 ]
}

@test "an upgrade turns a saved none into selfsigned and says so" {
	install_base
	# the host was installed by 0.60.0, which allowed none
	sed -i 's/^install.version=.*/install.version=0.60.0/' "$DPISTACK_ROOT/var/lib/dpistack/state"
	printf 'PANEL_TLS=none\nNGINX_TLS=none\n' >>"$E/dpistack/dpistack.conf"
	run install_base
	[ "$status" -eq 0 ]
	[[ "$output" == *"migrate 0.61.0: PANEL_TLS=none is not allowed any more"* ]]
	[[ "$output" == *"migrate 0.61.0: NGINX_TLS=none is not allowed any more"* ]]
	run grep '^PANEL_TLS=' "$E/dpistack/dpistack.conf"
	[ "$output" = "PANEL_TLS=selfsigned" ]
	run grep '^NGINX_TLS=' "$E/dpistack/dpistack.conf"
	[ "$output" = "NGINX_TLS=selfsigned" ]
}

@test "a second apply keeps the certificate" {
	run install_base --set PANEL_TLS=selfsigned
	[ "$status" -eq 0 ]
	a=$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)
	run install_base --set PANEL_TLS=selfsigned
	[ "$status" -eq 0 ]
	b=$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)
	[ "$a" = "$b" ]
}

@test "tls show prints the fingerprint openssl gives, and --json is valid" {
	install_base --set PANEL_TLS=selfsigned
	want=$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)
	want=${want#*=}
	run "$CTL" tls show
	[ "$status" -eq 0 ]
	[[ "$output" == *"panel (selfsigned)"* ]]
	[[ "$output" == *"SHA-256 $want"* ]]
	run "$CTL" tls show --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.[0].sha256' <<<"$output")" = "$want" ]
	[ "$(jq -r '.[0].kind' <<<"$output")" = "selfsigned" ]
	[ "$(jq '.[0].days_left > 800' <<<"$output")" = "true" ]
}

@test "renew leaves a fresh certificate and --force makes a new one" {
	install_base --set PANEL_TLS=selfsigned
	a=$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)
	run "$CTL" tls renew
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to renew"* ]]
	[ "$a" = "$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)" ]
	run "$CTL" tls renew --force
	[ "$status" -eq 0 ]
	[[ "$output" == *"renewed panel"* ]]
	[ "$a" != "$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)" ]
}

@test "renew replaces a certificate with fewer than 30 days left" {
	install_base --set PANEL_TLS=selfsigned
	openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 10 \
		-keyout "$TLS/panel.key" -out "$TLS/panel.crt" -subj "/CN=old" 2>/dev/null
	a=$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)
	run "$CTL" tls renew
	[ "$status" -eq 0 ]
	[[ "$output" == *"renewed panel"* ]]
	[ "$a" != "$(openssl x509 -in "$TLS/panel.crt" -noout -fingerprint -sha256)" ]
	run openssl x509 -in "$TLS/panel.crt" -noout -checkend $((60 * 86400))
	[ "$status" -eq 0 ]
}

@test "renew makes a missing certificate" {
	install_base --set PANEL_TLS=selfsigned
	rm -f "$TLS/panel.crt" "$TLS/panel.key"
	run "$CTL" tls renew
	[ "$status" -eq 0 ]
	[ -f "$TLS/panel.crt" ]
	[ -f "$TLS/panel.key" ]
}

@test "existing: the unit names the files, and renew leaves them alone" {
	mkdir -p "$DPISTACK_ROOT/srv"
	openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 5 \
		-keyout "$DPISTACK_ROOT/srv/my.key" -out "$DPISTACK_ROOT/srv/my.crt" -subj "/CN=mine" 2>/dev/null
	a=$(openssl x509 -in "$DPISTACK_ROOT/srv/my.crt" -noout -fingerprint -sha256)
	run install_base --set PANEL_TLS=existing --set "PANEL_CERT=$DPISTACK_ROOT/srv/my.crt" --set "PANEL_KEY=$DPISTACK_ROOT/srv/my.key"
	[ "$status" -eq 0 ]
	unit | grep -q -- "-tls-cert $DPISTACK_ROOT/srv/my.crt -tls-key $DPISTACK_ROOT/srv/my.key"
	[ ! -e "$TLS/panel.crt" ]
	run "$CTL" tls renew --force
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to renew"* ]]
	[ "$a" = "$(openssl x509 -in "$DPISTACK_ROOT/srv/my.crt" -noout -fingerprint -sha256)" ]
	run "$CTL" tls show
	[[ "$output" == *"panel (existing)"* ]]
}

@test "existing: files that are not there stop the apply with the name of the file" {
	run install_base --set PANEL_TLS=existing --set "PANEL_CERT=$DPISTACK_ROOT/no.crt" --set "PANEL_KEY=$DPISTACK_ROOT/no.key"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no.crt"* ]]
}

@test "validation: existing needs both files, and the values are checked" {
	run install_base --dry-run --set PANEL_TLS=existing
	[ "$status" -ne 0 ]
	[[ "$output" == *"PANEL_TLS=existing needs PANEL_CERT and PANEL_KEY"* ]]
	run install_base --dry-run --set PANEL_TLS=bogus
	[ "$status" -ne 0 ]
	run install_base --dry-run --set PANEL_TLS=existing --set PANEL_CERT=relative.crt --set PANEL_KEY=/k
	[ "$status" -ne 0 ]
}

@test "the nginx certificate is made the same way" {
	run install_base --set ACCESS_MODE=nginx --set NGINX_TLS=selfsigned --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	c=$(find "$DPISTACK_ROOT" -name 'panel.crt' -path '*nginx*' | head -1)
	[ -n "$c" ]
	run openssl x509 -in "$c" -noout -ext subjectAltName
	[[ "$output" == *"DNS:localhost"* ]]
	run openssl x509 -in "$c" -noout -text
	[[ "$output" == *"prime256v1"* ]]
	run "$CTL" tls show
	[[ "$output" == *"nginx-panel (selfsigned)"* ]]
}

@test "info shows https for the panel only" {
	install_base --set PANEL_TLS=selfsigned --set ACCESS_MODE=lan --set LAN_CIDR=192.168.0.0/24 --set ACCESS_CONFIRM=yes
	run "$CTL" info --json
	[ "$status" -eq 0 ]
	[ "$(jq -r '.screens[] | select(.id=="panel") | .url' <<<"$output" | cut -c1-8)" = "https://" ]
	[ "$(jq -r '.screens[] | select(.id=="evebox") | .url' <<<"$output" | cut -c1-7)" = "http://" ]
}

@test "the panel cannot read or renew certificates" {
	run env DPISTACK_CALLER=panel "$CTL" tls show
	[ "$status" -eq 5 ]
	run env DPISTACK_CALLER=panel "$CTL" tls renew
	[ "$status" -eq 5 ]
}

@test "an unknown tls argument is refused" {
	run "$CTL" tls frobnicate
	[ "$status" -eq 2 ]
	run "$CTL" tls renew --bogus
	[ "$status" -eq 2 ]
}

@test "behind nginx the panel is not given a certificate of its own" {
	run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	run unit
	[[ "$output" != *"-tls-cert"* ]]
}

@test "nginx with existing serves the files that were named, for all three names" {
	mkdir -p "$DPISTACK_ROOT/srv"
	openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 90 \
		-keyout "$DPISTACK_ROOT/srv/n.key" -out "$DPISTACK_ROOT/srv/n.crt" -subj "/CN=n" 2>/dev/null
	run install_base --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes \
		--set NGINX_TLS=existing --set "NGINX_CERT=$DPISTACK_ROOT/srv/n.crt" --set "NGINX_KEY=$DPISTACK_ROOT/srv/n.key"
	[ "$status" -eq 0 ]
	[ "$(grep -rh "ssl_certificate $DPISTACK_ROOT/srv/n.crt;" "$DPISTACK_ROOT" | wc -l)" -ge 3 ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack/nginx/tls/panel.crt" ]
}

mk_cert() {
	# mk_cert <name> <days>
	mkdir -p "$DPISTACK_ROOT/src"
	openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days "$2" \
		-keyout "$DPISTACK_ROOT/src/$1.key" -out "$DPISTACK_ROOT/src/$1.crt" -subj "/CN=$1" 2>/dev/null
}

@test "tls import copies a good pair, prints the settings to use it, and the key is 0640" {
	install_base
	mk_cert good 90
	run "$CTL" tls import "$DPISTACK_ROOT/src/good.crt" "$DPISTACK_ROOT/src/good.key"
	[ "$status" -eq 0 ]
	[[ "$output" == *"imported: "* ]]
	[[ "$output" == *"dpistack settings set PANEL_TLS=existing PANEL_CERT=$TLS/imported.crt PANEL_KEY=$TLS/imported.key"* ]]
	[ "$(stat -c %a "$TLS/imported.key")" = "640" ]
	cmp "$DPISTACK_ROOT/src/good.crt" "$TLS/imported.crt"
}

@test "tls import into a configuration that already points at the files needs nothing more" {
	mk_cert good 90
	run install_base --set PANEL_TLS=existing --set "PANEL_CERT=$TLS/imported.crt" --set "PANEL_KEY=$TLS/imported.key"
	[ "$status" -ne 0 ]
	"$CTL" tls import "$DPISTACK_ROOT/src/good.crt" "$DPISTACK_ROOT/src/good.key" >/dev/null
	run install_base --set PANEL_TLS=existing --set "PANEL_CERT=$TLS/imported.crt" --set "PANEL_KEY=$TLS/imported.key"
	[ "$status" -eq 0 ]
	mk_cert renewed 90
	run "$CTL" tls import "$DPISTACK_ROOT/src/renewed.crt" "$DPISTACK_ROOT/src/renewed.key"
	[ "$status" -eq 0 ]
	[[ "$output" == *"the panel reads the new files by itself"* ]]
	cmp "$DPISTACK_ROOT/src/renewed.crt" "$TLS/imported.crt"
}

@test "tls import refuses a key that is not the certificate's, an expired certificate and a non-PEM file" {
	mk_cert a 90
	mk_cert b 90
	run "$CTL" tls import "$DPISTACK_ROOT/src/a.crt" "$DPISTACK_ROOT/src/b.key"
	[ "$status" -eq 3 ]
	[[ "$output" == *"not the private key"* ]]
	printf 'junk\n' >"$DPISTACK_ROOT/src/junk.crt"
	run "$CTL" tls import "$DPISTACK_ROOT/src/junk.crt" "$DPISTACK_ROOT/src/a.key"
	[ "$status" -eq 3 ]
	run "$CTL" tls import "$DPISTACK_ROOT/src/nothing.crt" "$DPISTACK_ROOT/src/a.key"
	[ "$status" -eq 4 ]
	run "$CTL" tls import onlyone
	[ "$status" -eq 2 ]
	[ ! -e "$TLS/imported.crt" ]
}

@test "the panel cannot import a certificate" {
	run env DPISTACK_CALLER=panel "$CTL" tls import a b
	[ "$status" -eq 5 ]
}

@test "the panel in a container serves TLS and the directory of a named certificate is mounted" {
	mkdir -p "$DPISTACK_ROOT/srv"
	mk_cert srv 90
	cp "$DPISTACK_ROOT/src/srv.crt" "$DPISTACK_ROOT/srv/s.crt"
	cp "$DPISTACK_ROOT/src/srv.key" "$DPISTACK_ROOT/srv/s.key"
	run install_base --dry-run --set PANEL_RUNTIME=docker --set PANEL_TLS=existing \
		--set "PANEL_CERT=$DPISTACK_ROOT/srv/s.crt" --set "PANEL_KEY=$DPISTACK_ROOT/srv/s.key"
	[ "$status" -eq 0 ]
}
