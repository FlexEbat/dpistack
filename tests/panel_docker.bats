#!/usr/bin/env bats
# The panel as a container (PANEL_RUNTIME=docker) against the docker mock,
# and the whole matrix of runtimes in a dry run.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/dpistack-ctl"
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
	COMPOSE="$DPISTACK_ROOT/opt/dpistack/compose/compose.yaml"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

# The mixed scheme of criterion 1: Suricata native, EveBox and ntopng in docker.
install_mixed() {
	install_base --set EVEBOX_RUNTIME=docker --set NTOPNG_RUNTIME=docker "$@"
}

compose_cmd="docker compose -p dpistack -f"

@test "PANEL_RUNTIME=docker: a compose service with the host pid, the same file paths and the nsenter prefix" {
	MOCK_DOCKER_IMAGE_ABSENT=1 run install_base --set PANEL_RUNTIME=docker
	[ "$status" -eq 0 ]
	grep -q '^  panel:$' "$COMPOSE"
	grep -q '    network_mode: host' "$COMPOSE"
	grep -q '    pid: host' "$COMPOSE"
	grep -q '    privileged: true' "$COMPOSE"
	grep -q -- '"-sudo=false", "-ctl-prefix", "nsenter,-t,1,-m,-u,-i,-n,-p,--"' "$COMPOSE"
	grep -q -- '"-ctl", "'"$DPISTACK_ROOT"'/usr/local/sbin/dpistack"' "$COMPOSE"
	grep -q "image: dpistack-panel:[0-9a-f]\{12\}" "$COMPOSE"
	grep -q "$DPISTACK_ROOT/etc/dpistack:$DPISTACK_ROOT/etc/dpistack:ro" "$COMPOSE"
	grep -q "$DPISTACK_ROOT/var/log/suricata:$DPISTACK_ROOT/var/log/suricata:ro" "$COMPOSE"
}

@test "PANEL_RUNTIME=docker: the image is built from a directory with the binary, the native unit is gone" {
	MOCK_DOCKER_IMAGE_ABSENT=1 run install_base --set PANEL_RUNTIME=docker
	[ "$status" -eq 0 ]
	grep -q 'docker build -t dpistack-panel:' "$MOCK_CALLS_LOG"
	grep -q "docker compose -p dpistack -f .* up -d panel" "$MOCK_CALLS_LOG"
	grep -q 'systemctl disable --now dpistack-panel.service' "$MOCK_CALLS_LOG" || grep -q 'systemctl is-active --quiet dpistack-panel.service' "$MOCK_CALLS_LOG"
	[ ! -e "$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service" ]
	[ -x "$DPISTACK_ROOT/usr/local/bin/dpistack-panel" ]
}

@test "PANEL_RUNTIME=docker: an image that exists is not built again" {
	run install_base --set PANEL_RUNTIME=docker
	[ "$status" -eq 0 ]
	! grep -q 'docker build' "$MOCK_CALLS_LOG"
}

@test "PANEL_RUNTIME=docker: the second run is a no-op when the container is up" {
	MOCK_DOCKER_RUNNING="panel" run install_base --set PANEL_RUNTIME=docker
	[ "$status" -eq 0 ]
	: >"$MOCK_CALLS_LOG"
	MOCK_DOCKER_RUNNING="panel" run install_base --set PANEL_RUNTIME=docker
	[ "$status" -eq 0 ]
	! grep -q 'up -d panel' "$MOCK_CALLS_LOG"
}

@test "PANEL_RUNTIME=docker then native: the container is removed and the unit is back" {
	MOCK_DOCKER_RUNNING="panel" run install_base --set PANEL_RUNTIME=docker
	: >"$MOCK_CALLS_LOG"
	MOCK_DOCKER_RUNNING="panel" run install_base --set PANEL_RUNTIME=native
	[ "$status" -eq 0 ]
	grep -q 'rm -fsv panel' "$MOCK_CALLS_LOG"
	[ -f "$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service" ]
}

@test "PANEL_RUNTIME=docker with PANEL_MODE=unlimited passes the stream cap to the container" {
	run install_base --set PANEL_RUNTIME=docker --set PANEL_MODE=unlimited
	[ "$status" -eq 0 ]
	grep -q -- '"-max-streams", "32"' "$COMPOSE"
}

@test "the panel container asks for the verbs only: DPISTACK_CALLER=panel refuses installer commands" {
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" uninstall
	[ "$status" -eq 2 ]
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" version
	[ "$status" -eq 0 ]
}

# Every combination of where each component runs is a valid plan.
@test "runtime matrix: every native/docker combination of the five components plans without error" {
	n=0
	for s in native docker; do for e in native docker; do for t in native docker; do for m in none-native none-docker; do for p in native docker; do
		backend=none
		mrt=native
		[[ "$m" == none-docker ]] && { backend=victoriametrics; mrt=docker; }
		run install_base --dry-run --set SURICATA_RUNTIME=$s --set EVEBOX_RUNTIME=$e --set NTOPNG_RUNTIME=$t \
			--set METRICS_BACKEND=$backend --set METRICS_BACKEND_RUNTIME=$mrt --set PANEL_RUNTIME=$p
		if [ "$status" -ne 0 ]; then
			echo "combination $s $e $t $backend/$mrt $p failed: $output" >&2
			return 1
		fi
		n=$((n + 1))
	done; done; done; done; done
	[ "$n" -eq 32 ]
}
