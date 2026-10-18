#!/usr/bin/env bats
# Slice 27 criteria 1, 2, 3, 5, 6 against the docker mock. Criterion 4
# (images and volume paths, assumption A6) and a real container start are
# not covered: see tech.md 18.17.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/bin/dpistack-ctl"
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

@test "criterion 6: docker is accepted for suricata, evebox and ntopng" {
	for key in SURICATA_RUNTIME EVEBOX_RUNTIME NTOPNG_RUNTIME; do
		run install_base --dry-run --set "$key=docker"
		[ "$status" -eq 0 ]
		[[ "$output" != *"пока не поддерживается"* ]]
	done
}

@test "criterion 1: the mixed scheme brings up evebox, redis and ntopng in docker and Suricata natively" {
	run install_mixed
	[ "$status" -eq 0 ]
	grep -q "^  evebox:" "$COMPOSE"
	grep -q "^  redis:" "$COMPOSE"
	grep -q "^  ntopng:" "$COMPOSE"
	! grep -q "^  suricata:" "$COMPOSE"
	for svc in evebox redis ntopng; do
		grep -q "^docker compose -p dpistack -f $COMPOSE up -d $svc\$" "$MOCK_CALLS_LOG"
	done
	# Suricata went the native way, the docker components did not install packages
	grep -q '^systemctl enable --now suricata.service' "$MOCK_CALLS_LOG"
	! grep -q '^apt-get install -y .*evebox' "$MOCK_CALLS_LOG"
	! grep -q '^apt-get install -y .*ntopng' "$MOCK_CALLS_LOG"
	! grep -q '^systemctl enable --now evebox.service' "$MOCK_CALLS_LOG"
}

@test "criterion 1: a repeat run with everything up changes nothing" {
	install_mixed
	: >"$MOCK_CALLS_LOG"
	MOCK_DOCKER_RUNNING="evebox redis ntopng" run install_mixed
	[ "$status" -eq 0 ]
	! grep -q ' up -d ' "$MOCK_CALLS_LOG"
}

@test "criterion 3: containers read eve.json at the same host path, the same file the panel reads" {
	run install_mixed
	[ "$status" -eq 0 ]
	grep -q "/var/log/suricata:/var/log/suricata:ro" "$COMPOSE"
	grep -q "/var/log/suricata/eve.json" "$DPISTACK_ROOT/etc/evebox/evebox.yaml"
	run install_base --set SURICATA_RUNTIME=docker --set EVEBOX_RUNTIME=docker
	[ "$status" -eq 0 ]
	# one directory on the host is both the Suricata container's log and EveBox's input
	[ "$(grep -c "${DPISTACK_ROOT}/var/log/suricata:/var/log/suricata" "$COMPOSE")" -eq 2 ]
}

@test "Suricata in docker: host network, the capture capabilities, no package install" {
	run install_base --set SURICATA_RUNTIME=docker
	[ "$status" -eq 0 ]
	grep -q "^  suricata:" "$COMPOSE"
	grep -q "network_mode: host" "$COMPOSE"
	grep -q "cap_add: \[NET_ADMIN, NET_RAW, SYS_NICE\]" "$COMPOSE"
	grep -q "$compose_cmd $COMPOSE up -d suricata\$" "$MOCK_CALLS_LOG"
	! grep -q '^systemctl enable --now suricata.service' "$MOCK_CALLS_LOG"
	[ -f "$DPISTACK_ROOT/etc/suricata/suricata.yaml" ]
}

@test "Suricata in docker with nDPI on stops in preflight with code 3" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=source --set NDPI_ENABLE=yes --set SURICATA_RUNTIME=docker
	[ "$status" -eq 3 ]
	[[ "$output" == *"плагин nDPI"* ]]
	[ ! -f "$COMPOSE" ]
}

@test "a docker without the compose plugin stops in preflight with code 3" {
	MOCK_DOCKER_COMPOSE_EXIT=1 run install_base --set EVEBOX_RUNTIME=docker
	[ "$status" -eq 3 ]
	[[ "$output" == *"нет плагина compose"* ]]
}

@test "criterion 5: dpistack leaves iptables, DOCKER-USER and Docker networks alone" {
	run install_mixed --set SURICATA_RUNTIME=docker
	[ "$status" -eq 0 ]
	! grep -qE '^(iptables|ip6tables|nft) ' "$MOCK_CALLS_LOG"
	! grep -q "DOCKER-USER" "$MOCK_CALLS_LOG"
	! grep -qE '^docker (network|run|exec) ' "$MOCK_CALLS_LOG"
	# host networking only: no published ports, no networks of our own
	! grep -qE '^\s*(ports|networks):' "$COMPOSE"
	[ "$(grep -c "network_mode: host" "$COMPOSE")" -eq 4 ]
}

@test "criterion 2: status shows docker components with state, runtime and image" {
	install_mixed
	MOCK_DOCKER_PS=$'evebox running\nredis running\nntopng exited' MOCK_DOCKER_IMAGE="jasonish/evebox:latest" \
		run "$CTL" status --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e '.components[] | select(.id=="evebox") | .runtime=="docker" and .state=="active" and .enabled==true and .version=="jasonish/evebox:latest"'
	echo "$output" | jq -e '.components[] | select(.id=="ntopng") | .runtime=="docker" and .state=="inactive"'
	echo "$output" | jq -e '.components[] | select(.id=="redis") | .runtime=="docker" and .state=="active"'
	# Suricata is native and untouched by docker
	echo "$output" | jq -e '.components[] | select(.id=="suricata") | .runtime=="native"'
}

@test "criterion 2: a restarting container is reported failed" {
	install_mixed
	MOCK_DOCKER_PS=$'evebox restarting' run "$CTL" status --json
	echo "$output" | jq -e '.components[] | select(.id=="evebox") | .state=="failed"'
}

@test "criterion 2: start, stop and restart go through docker compose, not systemctl" {
	install_mixed
	: >"$MOCK_CALLS_LOG"
	for verb in start stop restart; do
		MOCK_DOCKER_PS=$'evebox running' run "$CTL" "$verb" evebox
		[ "$status" -eq 0 ]
		grep -q "^$compose_cmd $COMPOSE $verb evebox\$" "$MOCK_CALLS_LOG"
	done
	! grep -q '^systemctl \(start\|stop\|restart\) evebox' "$MOCK_CALLS_LOG"
}

@test "criterion 2: a docker component that is not there is code 4, as a missing unit is" {
	install_mixed
	MOCK_DOCKER_PS="" run "$CTL" restart evebox
	[ "$status" -eq 4 ]
}

@test "criterion 2: logs come from docker compose logs, with -n and --follow" {
	install_mixed
	: >"$MOCK_CALLS_LOG"
	MOCK_DOCKER_PS=$'evebox running' run "$CTL" logs evebox -n 50
	[ "$status" -eq 0 ]
	grep -q "^$compose_cmd $COMPOSE logs --no-color --tail 50 evebox\$" "$MOCK_CALLS_LOG"
	MOCK_DOCKER_PS=$'evebox running' run "$CTL" logs evebox -n 5 --follow
	grep -q "^$compose_cmd $COMPOSE logs --no-color --tail 5 --follow evebox\$" "$MOCK_CALLS_LOG"
	! grep -q '^journalctl' "$MOCK_CALLS_LOG"
}

@test "criterion 2: reload of a Suricata in docker goes through the container socket" {
	install_base --set SURICATA_RUNTIME=docker
	: >"$MOCK_CALLS_LOG"
	MOCK_DOCKER_PS=$'suricata running' run "$CTL" reload suricata
	[ "$status" -eq 0 ]
	grep -q "exec -T suricata suricatasc -c ruleset-reload-nonblocking /var/run/suricata/suricata-command.socket" "$MOCK_CALLS_LOG"
	! grep -q '^suricatasc' "$MOCK_CALLS_LOG"
}

@test "criterion 2: applying evebox.yaml restarts the container" {
	install_mixed
	: >"$MOCK_CALLS_LOG"
	staged=$(mktemp)
	cat "$DPISTACK_ROOT/etc/evebox/evebox.yaml" >"$staged"
	MOCK_DOCKER_PS=$'evebox running' run "$CTL" config-write evebox.yaml --apply <"$staged"
	rm -f "$staged"
	[ "$status" -eq 0 ]
	grep -q "^$compose_cmd $COMPOSE restart evebox\$" "$MOCK_CALLS_LOG"
}

@test "criterion 2: a Suricata config is checked in the container, with the scratch directory mounted" {
	install_base --set SURICATA_RUNTIME=docker
	: >"$MOCK_CALLS_LOG"
	MOCK_DOCKER_PS=$'suricata running' run "$CTL" config-write suricata.yaml --check <"$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	[ "$status" -eq 0 ]
	grep -qE "^$compose_cmd $COMPOSE run --rm --no-deps -v [^ ]+:/dpistack-check suricata -T -c /dpistack-check/suricata.yaml -l /dpistack-check\$" "$MOCK_CALLS_LOG"
	! grep -q '^suricata ' "$MOCK_CALLS_LOG"
}

@test "the BitTorrent replay is skipped with a reason when Suricata runs in docker" {
	run install_base --set SURICATA_RUNTIME=docker
	[ "$status" -eq 0 ]
	[[ "$output" == *"bittorrent: skip"* ]]
	[[ "$output" == *"Suricata в контейнере"* ]]
	[[ "$output" != *"suricata не установлен"* ]]
}

@test "a native component keeps its units: nothing changed for runtime native" {
	run install_base
	[ "$status" -eq 0 ]
	[ ! -f "$COMPOSE" ]
	! grep -q '^docker ' "$MOCK_CALLS_LOG"
	grep -q '^systemctl enable --now evebox.service' "$MOCK_CALLS_LOG"
}
