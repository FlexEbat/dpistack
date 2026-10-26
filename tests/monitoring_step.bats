#!/usr/bin/env bats
# node_exporter and Grafana: each is optional and chosen on its own, native
# or docker, and works with or without a metrics backend. The release
# downloads are fake tarballs behind the curl mock; the sha256 check runs for
# real against them.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	MOCK_IP_DEFAULT_IFACE="enp2s0"
	MOCK_IP_LINK_ROUTE="192.168.10.0/24"
	export MOCK_IP_EXISTING_IFACES MOCK_IP_DEFAULT_IFACE MOCK_IP_LINK_ROUTE
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	DPISTACK_METRICS_ARCH=amd64
	export DPISTACK_METRICS_ARCH

	REL="$(mktemp -d)"
	mkdir -p "$REL/ne/node_exporter-1.12.1.linux-amd64" "$REL/gf/grafana-v12.2.0/bin" "$REL/vm"
	printf '#!/bin/sh\necho fake-node\n' >"$REL/ne/node_exporter-1.12.1.linux-amd64/node_exporter"
	printf '#!/bin/sh\necho fake-grafana\n' >"$REL/gf/grafana-v12.2.0/bin/grafana"
	printf '#!/bin/sh\necho fake-vm\n' >"$REL/vm/victoria-metrics-prod"
	chmod +x "$REL/ne/node_exporter-1.12.1.linux-amd64/node_exporter" "$REL/gf/grafana-v12.2.0/bin/grafana" "$REL/vm/victoria-metrics-prod"
	tar -czf "$REL/ne.tar.gz" -C "$REL/ne" node_exporter-1.12.1.linux-amd64
	tar -czf "$REL/gf.tar.gz" -C "$REL/gf" grafana-v12.2.0
	tar -czf "$REL/vm.tar.gz" -C "$REL/vm" victoria-metrics-prod
	DPISTACK_NODEEXP_SHA256_AMD64="$(sha256sum "$REL/ne.tar.gz" | awk '{print $1}')"
	DPISTACK_GRAFANA_SHA256="$(sha256sum "$REL/gf.tar.gz" | awk '{print $1}')"
	DPISTACK_METRICS_SHA256_VM_AMD64="$(sha256sum "$REL/vm.tar.gz" | awk '{print $1}')"
	export DPISTACK_NODEEXP_SHA256_AMD64 DPISTACK_GRAFANA_SHA256 DPISTACK_METRICS_SHA256_VM_AMD64

	NE_UNIT="$DPISTACK_ROOT/etc/systemd/system/dpistack-node-exporter.service"
	GF_UNIT="$DPISTACK_ROOT/etc/systemd/system/dpistack-grafana.service"
	GF_INI="$DPISTACK_ROOT/etc/dpistack/grafana.ini"
	GF_DS="$DPISTACK_ROOT/etc/dpistack/grafana-provisioning/datasources/dpistack.yaml"
	SCRAPE="$DPISTACK_ROOT/var/lib/dpistack/scrape.yaml"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$REL"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

# The curl mock answers every download with one file; run the install once
# per tarball so each step gets its own.
with_ne() { MOCK_CURL_BODY_FILE="$REL/ne.tar.gz" install_base --set NODE_EXPORTER_ENABLE=yes "$@"; }
with_gf() { MOCK_CURL_BODY_FILE="$REL/gf.tar.gz" install_base --set GRAFANA_ENABLE=yes "$@"; }

@test "NODE_EXPORTER_ENABLE=yes installs node_exporter on 127.0.0.1:9100 with its own unit" {
	run with_ne
	[ "$status" -eq 0 ]
	[ -x "$DPISTACK_ROOT/usr/local/bin/node_exporter" ]
	grep -q -- '--web.listen-address=127.0.0.1:9100' "$NE_UNIT"
	grep -q '^User=dpistack-monitor$' "$NE_UNIT"
	grep -q 'systemctl enable --now dpistack-node-exporter.service' "$MOCK_CALLS_LOG"
}

@test "node_exporter, Grafana and the metrics backend are separate: choosing one installs none of the others" {
	run with_ne
	[ "$status" -eq 0 ]
	[ ! -e "$GF_UNIT" ]
	[ ! -e "$DPISTACK_ROOT/etc/systemd/system/dpistack-vm.service" ]
}

@test "Grafana alone: unit, ini on 127.0.0.1:3030, no data source without a backend" {
	run with_gf
	[ "$status" -eq 0 ]
	[ -x "$DPISTACK_ROOT/opt/dpistack/grafana/bin/grafana" ]
	grep -q -- '--config=' "$GF_UNIT"
	grep -q '^http_addr = 127.0.0.1$' "$GF_INI"
	grep -q '^http_port = 3030$' "$GF_INI"
	[ ! -e "$GF_DS" ]
	[ ! -e "$NE_UNIT" ]
}

@test "Grafana with VictoriaMetrics: the backend is the default data source" {
	run env MOCK_CURL_BODY_FILE="$REL/vm.tar.gz" bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set METRICS_BACKEND=victoriametrics
	[ "$status" -eq 0 ]
	run with_gf --set METRICS_BACKEND=victoriametrics
	[ "$status" -eq 0 ]
	grep -q 'url: http://127.0.0.1:8428' "$GF_DS"
	grep -q 'isDefault: true' "$GF_DS"
}

@test "node_exporter with a backend: the scrape file gets a node job pointing at it" {
	run env MOCK_CURL_BODY_FILE="$REL/vm.tar.gz" bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set METRICS_BACKEND=victoriametrics
	[ "$status" -eq 0 ]
	run with_ne --set METRICS_BACKEND=victoriametrics
	[ "$status" -eq 0 ]
	grep -q 'job_name: node' "$SCRAPE"
	grep -q "targets: \['127.0.0.1:9100'\]" "$SCRAPE"
}

@test "a wrong sha256 stops the install and leaves no binary" {
	DPISTACK_NODEEXP_SHA256_AMD64="0000000000000000000000000000000000000000000000000000000000000000" run with_ne
	[ "$status" -ne 0 ]
	[[ "$output" == *"the checksum"*"did not match"* ]]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/node_exporter" ]
	DPISTACK_GRAFANA_SHA256="1111111111111111111111111111111111111111111111111111111111111111" run with_gf
	[ "$status" -ne 0 ]
	[ ! -e "$DPISTACK_ROOT/opt/dpistack/grafana/bin/grafana" ]
}

@test "GRAFANA_RUNTIME=docker and NODE_EXPORTER_RUNTIME=docker are compose services" {
	run install_base --set GRAFANA_ENABLE=yes --set GRAFANA_RUNTIME=docker \
		--set NODE_EXPORTER_ENABLE=yes --set NODE_EXPORTER_RUNTIME=docker
	[ "$status" -eq 0 ]
	compose="$DPISTACK_ROOT/opt/dpistack/compose/compose.yaml"
	grep -q '^  grafana:$' "$compose"
	grep -q 'GF_SERVER_HTTP_PORT: "3030"' "$compose"
	grep -q '^  node_exporter:$' "$compose"
	grep -q -- '--web.listen-address=127.0.0.1:9100' "$compose"
	[ ! -e "$GF_UNIT" ]
	[ ! -e "$NE_UNIT" ]
}

@test "turning a component off stops it and the next run reports no changes" {
	run with_ne
	[ "$status" -eq 0 ]
	run install_base --set NODE_EXPORTER_ENABLE=no --force
	[ "$status" -eq 0 ]
	grep -q 'systemctl disable --now dpistack-node-exporter.service' "$MOCK_CALLS_LOG"
	run bash "$REPO_DIR/install.sh" status
	[[ "$output" == *"nodeexp: ok"* ]]
}

@test "with BIND_ADDR the new services listen on that address" {
	MOCK_IP_ADDRS="enp2s0=192.168.1.156/24" run with_ne --set BIND_ADDR=192.168.1.156 \
		--set LAN_CIDR=192.168.1.0/24 --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -q -- '--web.listen-address=192.168.1.156:9100' "$NE_UNIT"
}

@test "uninstall removes node_exporter and Grafana" {
	run with_ne
	[ "$status" -eq 0 ]
	run with_gf --set NODE_EXPORTER_ENABLE=yes
	run bash "$REPO_DIR/install.sh" uninstall -y
	[ ! -e "$NE_UNIT" ]
	[ ! -e "$GF_UNIT" ]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/node_exporter" ]
}
