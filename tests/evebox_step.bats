#!/usr/bin/env bats
# Covers slice 6 criteria 2, 3, 5, plus the preflight port regression
# found while building this slice (a repeat run must not treat ports
# held by our own services as conflicts).

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
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	CONF_YAML="$DPISTACK_ROOT/etc/evebox/evebox.yaml"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "criterion 2: unreachable EVEBOX_ES_URL stops with code 3 before any package or unit" {
	MOCK_EXIT=7 run install_base \
		--set EVEBOX_DB=elasticsearch --set EVEBOX_ES_URL=http://es.invalid:9200
	[ "$status" -eq 3 ]
	[[ "$output" == *"EVEBOX_ES_URL"* ]]
	run grep -c "apt-get install\|systemctl enable" "$MOCK_CALLS_LOG"
	[ "$output" = "0" ]
	[ ! -e "$CONF_YAML" ]
}

@test "criterion 2: reachable EVEBOX_ES_URL installs and renders the elasticsearch block" {
	run install_base \
		--set EVEBOX_DB=elasticsearch --set EVEBOX_ES_URL=http://es.local:9200
	[ "$status" -eq 0 ]
	grep -q '^  type: elasticsearch$' "$CONF_YAML"
	grep -q 'url: http://es.local:9200' "$CONF_YAML"
}

@test "criterion 3: EVE_FILE=no with sqlite is refused with code 2 and explains why" {
	run install_base --set EVE_FILE=no
	[ "$status" -eq 2 ]
	[[ "$output" == *"EveBox не сможет читать события"* ]]
	[ ! -e "$CONF_YAML" ]
}

@test "criterion 3: EVE_FILE=no is fine with elasticsearch" {
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set EVE_FILE=no --set EVEBOX_DB=elasticsearch --set EVEBOX_ES_URL=http://es.local:9200
	[ "$status" -eq 0 ]
}

@test "retention: EVEBOX_RETENTION_DAYS=0 renders 0, which EveBox documents as disabled" {
	run install_base --set EVEBOX_RETENTION_DAYS=0
	[ "$status" -eq 0 ]
	grep -q '^    days: 0$' "$CONF_YAML"
}

@test "criterion 5: a second run reports no changes for evebox" {
	run install_base
	[ "$status" -eq 0 ]
	[ -f "$CONF_YAML" ]
	run bash "$REPO_DIR/install.sh" status --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"evebox: в порядке"* ]]
}

@test "preflight: a busy EVEBOX_PORT held by a stranger stops the install with code 3" {
	MOCK_SS_LISTEN="5636" run install_base
	[ "$status" -eq 3 ]
	[[ "$output" == *"порт 5636"* ]]
}

@test "preflight: ports held by our own already-installed services are not conflicts on a repeat run" {
	run install_base
	[ "$status" -eq 0 ]
	MOCK_SS_LISTEN="5636,3000" run install_base
	[ "$status" -eq 0 ]
}
