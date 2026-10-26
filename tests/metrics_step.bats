#!/usr/bin/env bats
# Slice 28 (tech.md 17), criteria 2, 3, 4, 7, 8 and the parts of 1, 5 and 6
# that need no real host. The release download is a fake tarball behind the
# curl mock; the sha256 check runs for real against it. Not covered: a real
# backend scraping a real panel (criterion 1), see tech.md 18.18.

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

	# Fake release tarballs with the layout of the real ones.
	REL="$(mktemp -d)"
	mkdir -p "$REL/vm" "$REL/prom/prometheus-3.15.0.linux-amd64"
	printf '#!/bin/sh\necho fake-vm\n' >"$REL/vm/victoria-metrics-prod"
	printf '#!/bin/sh\necho fake-prom\n' >"$REL/prom/prometheus-3.15.0.linux-amd64/prometheus"
	chmod +x "$REL/vm/victoria-metrics-prod" "$REL/prom/prometheus-3.15.0.linux-amd64/prometheus"
	tar -czf "$REL/vm.tar.gz" -C "$REL/vm" victoria-metrics-prod
	tar -czf "$REL/prom.tar.gz" -C "$REL/prom" prometheus-3.15.0.linux-amd64
	DPISTACK_METRICS_SHA256_VM_AMD64="$(sha256sum "$REL/vm.tar.gz" | awk '{print $1}')"
	DPISTACK_METRICS_SHA256_PROM_AMD64="$(sha256sum "$REL/prom.tar.gz" | awk '{print $1}')"
	export DPISTACK_METRICS_SHA256_VM_AMD64 DPISTACK_METRICS_SHA256_PROM_AMD64

	VM_UNIT="$DPISTACK_ROOT/etc/systemd/system/dpistack-vm.service"
	PROM_UNIT="$DPISTACK_ROOT/etc/systemd/system/prometheus.service"
	SCRAPE="$DPISTACK_ROOT/var/lib/dpistack/scrape.yaml"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$REL"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

with_vm() { MOCK_CURL_BODY_FILE="$REL/vm.tar.gz" install_base --set METRICS_BACKEND=victoriametrics "$@"; }
with_prom() { MOCK_CURL_BODY_FILE="$REL/prom.tar.gz" install_base --set METRICS_BACKEND=prometheus "$@"; }

token_value() { sed -n 's/^METRICS_TOKEN=//p' "$DPISTACK_ROOT/etc/dpistack/secrets.conf"; }

@test "criteria 2 and 4: VictoriaMetrics gets the retention and listens on 127.0.0.1 in localhost mode" {
	run with_vm --set METRICS_RETENTION=30d
	[ "$status" -eq 0 ]
	grep -q -- '-retentionPeriod=30d' "$VM_UNIT"
	grep -q -- '-httpListenAddr=127.0.0.1:8428' "$VM_UNIT"
	grep -q -- "-promscrape.config=$SCRAPE" "$VM_UNIT"
	grep -q -- "-storageDataPath=$DPISTACK_ROOT/var/lib/dpistack-metrics/victoriametrics" "$VM_UNIT"
	grep -q '^systemctl enable --now dpistack-vm.service' "$MOCK_CALLS_LOG"
	[ -x "$DPISTACK_ROOT/usr/local/bin/victoria-metrics-prod" ]
}

@test "criteria 2 and 4: Prometheus gets --storage.tsdb.retention.time and its own port" {
	run with_prom --set METRICS_RETENTION=90d
	[ "$status" -eq 0 ]
	grep -q -- '--storage.tsdb.retention.time=90d' "$PROM_UNIT"
	grep -q -- '--web.listen-address=127.0.0.1:9090' "$PROM_UNIT"
	grep -q -- "--config.file=$SCRAPE" "$PROM_UNIT"
	grep -q '^systemctl enable --now prometheus.service' "$MOCK_CALLS_LOG"
	[ -x "$DPISTACK_ROOT/usr/local/bin/prometheus" ]
}

@test "criterion 4: lan mode listens on 0.0.0.0 and opens the backend port for LAN_CIDR only; nginx mode stays on 127.0.0.1" {
	run with_vm --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes --set FIREWALL_MANAGE=auto --set LAN_CIDR=192.168.10.0/24
	[ "$status" -eq 0 ]
	grep -q -- '-httpListenAddr=0.0.0.0:8428' "$VM_UNIT"
	grep -E '^ufw .*192\.168\.10\.0/24.* 8428' "$MOCK_CALLS_LOG"
	rm -rf "$DPISTACK_ROOT/var" "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/etc/systemd" "$DPISTACK_ROOT/usr"
	run with_vm --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes --set METRICS_BACKEND_PORT=18428
	[ "$status" -eq 0 ]
	grep -q -- '-httpListenAddr=127.0.0.1:18428' "$VM_UNIT"
}

@test "criterion 3: the token is read from a file and appears nowhere else" {
	run with_vm
	[ "$status" -eq 0 ]
	tok=$(token_value)
	[ -n "$tok" ]
	grep -q "credentials_file: $DPISTACK_ROOT/etc/dpistack/metrics.token" "$SCRAPE"
	grep -q "targets: \['127.0.0.1:9800'\]" "$SCRAPE"
	if grep -rq -- "$tok" "$SCRAPE" "$VM_UNIT" "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"; then false; fi
	# not on the command line of any call either
	if grep -q -- "$tok" "$MOCK_CALLS_LOG"; then false; fi
	# the file itself is root:dpistack 0640, written before the backend starts
	[ "$(cat "$DPISTACK_ROOT/etc/dpistack/metrics.token")" = "$tok" ]
}

@test "criterion 3: behind nginx the collector scrapes the panel's own plain-HTTP port" {
	run with_vm --set ACCESS_MODE=nginx --set NGINX_MANAGE=snippet --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	grep -q "targets: \['127.0.0.1:19800'\]" "$SCRAPE"
	grep -q 'scheme: http' "$SCRAPE"
}

@test "criterion 5: the tarball's sha256 is checked, a mismatch installs nothing" {
	DPISTACK_METRICS_SHA256_VM_AMD64="0000000000000000000000000000000000000000000000000000000000000000" run with_vm
	[ "$status" -ne 0 ]
	[[ "$output" == *"the checksum"* ]]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/victoria-metrics-prod" ]
	[ ! -e "$VM_UNIT" ]
	! grep -q '^systemctl enable --now dpistack-vm.service' "$MOCK_CALLS_LOG"
}

@test "criterion 5: the download is HTTPS from the project's own GitHub release, at the pinned version" {
	run with_vm
	[ "$status" -eq 0 ]
	grep -q "^curl --proto =https --tlsv1.2 -fsSL -o .* https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.153.0/victoria-metrics-linux-amd64-v1.153.0.tar.gz\$" "$MOCK_CALLS_LOG"
	: >"$MOCK_CALLS_LOG"
	rm -rf "$DPISTACK_ROOT/var" "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/etc/systemd" "$DPISTACK_ROOT/usr"
	run with_prom
	[ "$status" -eq 0 ]
	grep -q "https://github.com/prometheus/prometheus/releases/download/v3.15.0/prometheus-3.15.0.linux-amd64.tar.gz" "$MOCK_CALLS_LOG"
}

@test "criterion 8: a repeat run changes nothing" {
	with_vm
	: >"$MOCK_CALLS_LOG"
	run with_vm
	[ "$status" -eq 0 ]
	if grep -qE '^curl .*(VictoriaMetrics|prometheus)/' "$MOCK_CALLS_LOG"; then false; fi
	if grep -q '^systemctl enable --now dpistack-vm' "$MOCK_CALLS_LOG"; then false; fi
	if grep -q '^systemctl restart dpistack-vm' "$MOCK_CALLS_LOG"; then false; fi
	! grep -q '^systemctl disable' "$MOCK_CALLS_LOG"
}

@test "criterion 7: another backend replaces the first, whose data stays" {
	with_vm
	[ -d "$DPISTACK_ROOT/var/lib/dpistack-metrics/victoriametrics" ]
	: >"$MOCK_CALLS_LOG"
	run with_prom
	[ "$status" -eq 0 ]
	grep -q '^systemctl disable --now dpistack-vm.service' "$MOCK_CALLS_LOG"
	grep -q '^systemctl enable --now prometheus.service' "$MOCK_CALLS_LOG"
	[ -d "$DPISTACK_ROOT/var/lib/dpistack-metrics/victoriametrics" ]
}

@test "criterion 7: none stops the backend and keeps its data" {
	with_vm
	: >"$MOCK_CALLS_LOG"
	run install_base --set METRICS_BACKEND=none
	[ "$status" -eq 0 ]
	grep -q '^systemctl disable --now dpistack-vm.service' "$MOCK_CALLS_LOG"
	[ -d "$DPISTACK_ROOT/var/lib/dpistack-metrics/victoriametrics" ]
	: >"$MOCK_CALLS_LOG"
	run install_base --set METRICS_BACKEND=none
	! grep -q '^systemctl disable' "$MOCK_CALLS_LOG"
}

@test "criterion 7: uninstall removes the unit and binary, the data only with --purge" {
	with_vm
	run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 0 ]
	[ ! -e "$VM_UNIT" ]
	[ ! -e "$DPISTACK_ROOT/usr/local/bin/victoria-metrics-prod" ]
	[ -d "$DPISTACK_ROOT/var/lib/dpistack-metrics/victoriametrics" ]
	with_vm
	run bash "$REPO_DIR/install.sh" uninstall --purge
	[ "$status" -eq 0 ]
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack-metrics" ]
}

@test "a retention that the two backends read differently is refused once a backend is set" {
	for bad in 6m 30; do
		run with_vm --set METRICS_RETENTION=$bad
		[ "$status" -eq 2 ]
		[[ "$output" == *"METRICS_RETENTION"* ]]
	done
	run install_base --set METRICS_BACKEND=none --set METRICS_RETENTION=6m
	[ "$status" -eq 0 ]
	for ok in 12h 30d 4w 1y; do
		run with_vm --dry-run --set METRICS_RETENTION=$ok
		[ "$status" -eq 0 ]
	done
}

@test "a dry run downloads and writes nothing" {
	run with_vm --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"victoriametrics v1.153.0"* ]]
	if grep -qE '^curl .*(VictoriaMetrics|prometheus)/' "$MOCK_CALLS_LOG"; then false; fi
	if grep -q '^useradd' "$MOCK_CALLS_LOG"; then false; fi
	[ ! -e "$VM_UNIT" ]
	[ ! -e "$SCRAPE" ]
}

@test "METRICS_BACKEND=none installs nothing and creates no user or data" {
	run install_base
	[ "$status" -eq 0 ]
	if grep -q 'dpistack-metrics' "$MOCK_CALLS_LOG"; then false; fi
	[ ! -e "$DPISTACK_ROOT/var/lib/dpistack-metrics" ]
	[ ! -e "$SCRAPE" ]
}

@test "the backend runs as its own user in the dpistack group" {
	# the getent mock says every user exists; here none does
	nouser="$(mktemp -d)"
	printf '#!/bin/sh\nexit 2\n' >"$nouser/getent"
	chmod +x "$nouser/getent"
	PATH="$nouser:$PATH" run with_vm
	rm -rf "$nouser"
	[ "$status" -eq 0 ]
	grep -q '^useradd --system --no-create-home --shell /usr/sbin/nologin -G dpistack dpistack-metrics' "$MOCK_CALLS_LOG"
	# the dpistack user is made first, so the group exists for -G
	[ "$(grep -n '^useradd .* dpistack$' "$MOCK_CALLS_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'dpistack-metrics$' "$MOCK_CALLS_LOG" | head -1 | cut -d: -f1)" ]
	grep -q '^User=dpistack-metrics' "$VM_UNIT"
	grep -q '^SupplementaryGroups=dpistack' "$VM_UNIT"
}

@test "docker runtime: one compose service, same-path mounts, the token read-only, pinned image tag" {
	run install_base --set METRICS_BACKEND=victoriametrics --set METRICS_BACKEND_RUNTIME=docker --set METRICS_RETENTION=45d
	[ "$status" -eq 0 ]
	compose="$DPISTACK_ROOT/opt/dpistack/compose/compose.yaml"
	grep -q '^  victoriametrics:' "$compose"
	grep -q 'image: victoriametrics/victoria-metrics:v1.153.0' "$compose"
	grep -q '"-retentionPeriod=45d"' "$compose"
	grep -q '"-httpListenAddr=127.0.0.1:8428"' "$compose"
	grep -q "$DPISTACK_ROOT/etc/dpistack/metrics.token:$DPISTACK_ROOT/etc/dpistack/metrics.token:ro" "$compose"
	grep -q 'network_mode: host' "$compose"
	grep -q "^docker compose -p dpistack -f $compose up -d victoriametrics\$" "$MOCK_CALLS_LOG"
	if grep -qE '^curl .*(VictoriaMetrics|prometheus)/' "$MOCK_CALLS_LOG"; then false; fi
	[ ! -e "$VM_UNIT" ]
}

@test "docker runtime: switching to none removes the container and keeps the data" {
	install_base --set METRICS_BACKEND=prometheus --set METRICS_BACKEND_RUNTIME=docker
	: >"$MOCK_CALLS_LOG"
	run install_base --set METRICS_BACKEND=none
	[ "$status" -eq 0 ]
	grep -q "^docker compose -p dpistack -f .* rm -fsv prometheus\$" "$MOCK_CALLS_LOG"
	[ -d "$DPISTACK_ROOT/var/lib/dpistack-metrics/prometheus" ]
}

@test "criterion 6: a docker backend answers to dpistack like a unit" {
	install_base --set METRICS_BACKEND=victoriametrics --set METRICS_BACKEND_RUNTIME=docker
	MOCK_DOCKER_PS=$'victoriametrics running' run "$REPO_DIR/tests/helpers/verbs" status --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.components[] | select(.id=="victoriametrics") | .runtime=="docker" and .state=="active"'
}

@test "a new pinned version replaces the old binary, a repeat run with the same version does not (R137)" {
	with_vm
	local bin="$DPISTACK_ROOT/usr/local/bin/victoria-metrics-prod"
	[ -x "$bin" ]
	echo stale >"$bin"
	chmod 0755 "$bin"
	# the state says an older version is installed
	sed -i 's#^metrics.backend=.*#metrics.backend=native:victoriametrics:v0.0.1#' "$DPISTACK_ROOT/var/lib/dpistack/state"
	: >"$MOCK_CALLS_LOG"
	run with_vm
	[ "$status" -eq 0 ]
	grep -q '^curl .*victoria' "$MOCK_CALLS_LOG"
	[ "$(grep -c '^stale$' "$bin")" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	echo keep >"$bin"
	run with_vm
	[ "$(grep -c '^curl .*victoria' "$MOCK_CALLS_LOG")" -eq 0 ]
	grep -q '^keep$' "$bin"
}
