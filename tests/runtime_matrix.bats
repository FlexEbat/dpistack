#!/usr/bin/env bats
# Slice 33: `dpistack runtime` (tech.md 4.10): the matrix of what can run in
# Docker, the mixed flag and the links between the parts.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/var/log/suricata"
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
show) echo loaded ;;
is-active) echo active ;;
is-enabled) exit 0 ;;
esac
FAKE
	printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN/dpkg-query"
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$PATH"
	export PATH
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
}

@test "the matrix lists every component of the program and says why a part cannot be a container" {
	run "$CTL" runtime --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e . >/dev/null
	for id in suricata evebox ntopng redis panel victoriametrics prometheus node_exporter grafana; do
		[ "$(echo "$output" | jq -r --arg i "$id" '.components[] | select(.id==$i) | .docker')" != "no" ] || {
			echo "$id"
			return 1
		}
	done
	for id in ndpi watch nginx firewall installer; do
		[ "$(echo "$output" | jq -r --arg i "$id" '.components[] | select(.id==$i) | .docker')" = "no" ]
		[ -n "$(echo "$output" | jq -r --arg i "$id" '.components[] | select(.id==$i) | .why')" ]
	done
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="redis") | .docker')" = "follows:ntopng" ]
}

@test "mixed is false with everything native and true when one part is a container" {
	run "$CTL" runtime --json
	[ "$(echo "$output" | jq -r .mixed)" = "false" ]
	printf 'EVEBOX_RUNTIME=docker\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" runtime --json
	[ "$(echo "$output" | jq -r .mixed)" = "true" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="evebox") | .runtime')" = "docker" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="suricata") | .runtime')" = "native" ]
}

@test "redis and the rules follow ntopng and Suricata" {
	printf 'NTOPNG_RUNTIME=docker\nSURICATA_RUNTIME=docker\nNDPI_ENABLE=no\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" runtime --json
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="redis") | .runtime')" = "docker" ]
	[ "$(echo "$output" | jq -r '.components[] | select(.id=="rules") | .runtime')" = "docker" ]
}

@test "a link is checked only when both ends run: the eve.json link is true with a readable file and false without" {
	run "$CTL" runtime --json
	[ "$(echo "$output" | jq -r '.links[] | select(.from=="suricata" and .to=="evebox") | .ok')" = "false" ]
	: >"$DPISTACK_ROOT/var/log/suricata/eve.json"
	run "$CTL" runtime --json
	[ "$(echo "$output" | jq -r '.links[] | select(.from=="suricata" and .to=="evebox") | .ok')" = "true" ]
}

@test "a tcp link follows the real listener: a listening port is true, a closed one is false" {
	port=$((30000 + RANDOM % 20000))
	printf 'METRICS_BACKEND=prometheus\nMETRICS_BACKEND_PORT=%s\nGRAFANA_ENABLE=yes\n' "$port" >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" runtime --json
	[ "$(echo "$output" | jq -r '.links[] | select(.from=="prometheus" and .to=="grafana") | .ok')" = "false" ]
	python3 -c "
import socket,time
s=socket.socket();s.bind(('127.0.0.1',$port));s.listen(5);time.sleep(8)" &
	pid=$!
	sleep 1
	run "$CTL" runtime --json
	kill "$pid" 2>/dev/null || true
	[ "$(echo "$output" | jq -r '.links[] | select(.from=="prometheus" and .to=="grafana") | .ok')" = "true" ]
}

@test "the verb refuses an unknown argument and is open to the panel" {
	run "$CTL" runtime --bogus
	[ "$status" -eq 2 ]
	grep -q 'health runtime' "$REPO_DIR/install.sh"
}
