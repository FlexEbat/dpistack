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
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

run_install() {
	run bash "$REPO_DIR/install.sh" install --dry-run -y "$@"
}

@test "unknown key exits 2 with a readable message" {
	run_install --set NOT_A_REAL_KEY=1
	[ "$status" -eq 2 ]
	[[ "$output" == *"неизвестный ключ: NOT_A_REAL_KEY"* ]]
}

@test "value outside options exits 2 with a readable message" {
	run_install --set ACCESS_MODE=carrier-pigeon
	[ "$status" -eq 2 ]
	[[ "$output" == *"ACCESS_MODE=carrier-pigeon"* ]]
	[[ "$output" == *"допустимо"* ]]
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

@test "not-yet-supported runtime value names itself as unsupported" {
	run_install --set SURICATA_RUNTIME=docker
	[ "$status" -eq 2 ]
	[[ "$output" == *"пока не поддерживается"* ]]
}

@test "not-yet-supported ips mode names itself as unsupported" {
	run_install --set SURICATA_MODE=ips
	[ "$status" -eq 2 ]
	[[ "$output" == *"пока не поддерживается"* ]]
}

@test "secret from --set goes to secrets.conf, not dpistack.conf or stdout" {
	run bash "$REPO_DIR/install.sh" install -y --set ALERT_TG_TOKEN=super-secret-token
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
