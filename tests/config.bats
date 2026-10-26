#!/usr/bin/env bats
# Covers slice 1 criteria 3, 4, 7: schema/cross-field validation exits
# 2 with a readable message, not-yet-implemented values say so, and
# secrets never land in dpistack.conf or on stdout.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	cat >"$DPISTACK_ROOT/etc/os-release" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

run_install() {
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "unknown key exits 2 with a readable message" {
	run_install --set NOT_A_REAL_KEY=1
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown key: NOT_A_REAL_KEY"* ]]
}

@test "value outside options exits 2 with a readable message" {
	run_install --set ACCESS_MODE=carrier-pigeon
	[ "$status" -eq 2 ]
	[[ "$output" == *"ACCESS_MODE=carrier-pigeon"* ]]
	[[ "$output" == *"allowed"* ]]
}

@test "EVEBOX_DB=elasticsearch without EVEBOX_ES_URL exits 2" {
	run_install --set EVEBOX_DB=elasticsearch
	[ "$status" -eq 2 ]
	[[ "$output" == *"EVEBOX_ES_URL"* ]]
}

@test "EVEBOX_DB=elasticsearch with EVEBOX_ES_URL passes validation" {
	run_install --set EVEBOX_DB=elasticsearch --set EVEBOX_ES_URL=http://es:9200
	[ "$status" -eq 0 ]
}

@test "METRICS_BACKEND victoriametrics with METRICS_EXPORT=no exits 2" {
	run_install --set METRICS_BACKEND=victoriametrics --set METRICS_EXPORT=no
	[ "$status" -eq 2 ]
}

@test "runtime docker is a supported value for every component, the metrics backend included" {
	run_install --dry-run --set METRICS_BACKEND=victoriametrics --set METRICS_BACKEND_RUNTIME=docker
	[ "$status" -eq 0 ]
	[[ "$output" != *"not supported yet"* ]]
}

@test "ips mode is a supported value now, with its own preconditions checked" {
	run_install --dry-run --set SURICATA_MODE=ips
	[ "$status" -eq 0 ]
	[[ "$output" != *"not supported yet"* ]]
}

@test "ACCESS_MODE=lan without confirmation exits 2 in non-interactive mode" {
	run_install --set ACCESS_MODE=lan
	[ "$status" -eq 2 ]
	[[ "$output" == *"ACCESS_CONFIRM"* ]]
}

@test "ACCESS_MODE=lan with --set ACCESS_CONFIRM=yes passes and is never persisted" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	conf_file="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	[ -f "$conf_file" ]
	run grep -c "ACCESS_CONFIRM" "$conf_file"
	[ "$output" = "0" ]
}

@test "secret from --set goes to secrets.conf, not dpistack.conf or stdout" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set ALERT_TG_TOKEN=super-secret-token
	[ "$status" -eq 0 ]
	[[ "$output" != *"super-secret-token"* ]]

	conf_file="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	secrets_file="$DPISTACK_ROOT/etc/dpistack/secrets.conf"
	[ -f "$conf_file" ]
	[ -f "$secrets_file" ]
	run grep -c "super-secret-token" "$conf_file"
	[ "$output" = "0" ]
	run grep -c "ALERT_TG_TOKEN=super-secret-token" "$secrets_file"
	[ "$output" = "1" ]

	perm=$(stat -c '%a' "$secrets_file")
	[ "$perm" = "600" ]
}

@test "reconfigure applies the affected steps in pipeline order, not in hash order" {
	cat >"$BATS_TEST_TMPDIR/t.sh" <<'EOF_T'
cd "$REPO_DIR"
source lib/paths.sh; source lib/common.sh; source lib/state.sh
source lib/schema.sh; source lib/config.sh
STEPS_ORDER=(preflight selfinstall ndpi suricata rules redis ntopng evebox metrics nodeexp grafana access panel watch verify)
config_reset; config_load_defaults
: >"$BATS_TEST_TMPDIR/old.conf"
config_diff_and_steps "$BATS_TEST_TMPDIR/old.conf" >/dev/null
echo "${CONFIG_AFFECTED_STEPS[*]}"
EOF_T
	run env REPO_DIR="$REPO_DIR" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" DPISTACK_ROOT="$(mktemp -d)" bash "$BATS_TEST_TMPDIR/t.sh"
	[ "$status" -eq 0 ]
	local want="" s
	for s in preflight selfinstall ndpi suricata rules redis ntopng evebox metrics nodeexp grafana access panel watch verify; do
		[[ " $output " == *" $s "* ]] && want+="$s "
	done
	[ "$output" = "${want% }" ]
}

@test "an integer with a leading zero is refused, not accepted as a bad octal number (R143)" {
	cat >"$BATS_TEST_TMPDIR/t.sh" <<'EOF_T'
cd "$REPO_DIR"
source lib/paths.sh; source lib/common.sh; source lib/state.sh
source lib/schema.sh
for v in 08 010 007 -05 5 0 100 -1; do
	if out=$(schema_validate_one WATCH_DISK_WARN_PCT "$v" 2>&1); then echo "$v ok"; else echo "$v refused: $out"; fi
done
EOF_T
	run env REPO_DIR="$REPO_DIR" DPISTACK_ROOT="$(mktemp -d)" bash "$BATS_TEST_TMPDIR/t.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"08 refused"* ]]
	[[ "$output" == *"010 refused"* ]]
	[[ "$output" == *"007 refused"* ]]
	[[ "$output" == *"-05 refused"* ]]
	[[ "$output" == *"5 ok"* ]]
	[[ "$output" == *"0 ok"* ]]
	[[ "$output" == *"100 ok"* ]]
	[[ "$output" == *"-1 refused"* ]] # a number, but out of the range 0..100
	[[ "$output" != *"value too great"* ]]
}
