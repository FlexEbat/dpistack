#!/usr/bin/env bats
# Migrations and build recipes (tech.md 18.57): what an upgrade does by itself.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	export MOCK_IP_EXISTING_IFACES=enp2s0 MOCK_IP_DEFAULT_IFACE=enp2s0 MOCK_IP_LINK_ROUTE=192.168.10.0/24
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

# lib <setup> <command> - the migration functions with a state file in the sandbox
lib() {
	bash -c '
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/state.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/step_ndpi.sh"
		source "'"$REPO_DIR"'/lib/step_suricata.sh"
		source "'"$REPO_DIR"'/lib/migrate.sh"
		config_reset
		config_load_defaults
		'"$1"'
		'"$2"'
	'
}

@test "a host without an install has nothing to migrate" {
	run lib '' 'migrate_plan'
	[ "$status" -eq 0 ]
	[[ "$output" == *"no finished install"* ]]
	run lib '' 'migrate_pending'
	[ -z "$output" ]
}

@test "an install that did not record its version is older than every migration" {
	run lib 'state_write_value install.finished yes' 'migrate_from_version; migrate_pending'
	[ "$status" -eq 0 ]
	[[ "$output" == *"0.0.0"* ]]
	[[ "$output" == *"0.50.0"* ]]
}

@test "a recorded version at or above a migration skips it, a lower one runs it" {
	run lib 'state_write_value install.finished yes; state_write_value install.version 0.50.0' 'migrate_pending'
	[ -z "$output" ]
	run lib 'state_write_value install.finished yes; state_write_value install.version 0.49.0' 'migrate_pending'
	[ "$output" = "0.50.0" ]
	# a migration of a version above this one is not run by an older program
	run lib 'state_write_value install.finished yes; state_write_value install.version 0.1.0; DPISTACK_VERSION=0.49.0' 'migrate_pending'
	[ -z "$output" ]
}

@test "0.50.0 gives an empty EVE_MAX_SIZE_MB its default and names a live EVE_REDIS" {
	run lib 'state_write_value install.finished yes; state_write_value install.version 0.49.0; CONF[EVE_MAX_SIZE_MB]=""; CONF[EVE_REDIS]="127.0.0.1:6379/eve"' 'migrate_run; echo "size=${CONF[EVE_MAX_SIZE_MB]}"'
	[ "$status" -eq 0 ]
	[[ "$output" == *"EVE_MAX_SIZE_MB was saved empty, it is 100 now"* ]]
	[[ "$output" == *"EVE_REDIS=127.0.0.1:6379/eve was ignored before and is a live Redis output now"* ]]
	[[ "$output" == *"size=100"* ]]
	# EVE_REDIS is left as the person wrote it
}

@test "a value that is already fine is not touched and says nothing" {
	run lib 'state_write_value install.finished yes; state_write_value install.version 0.49.0; CONF[EVE_MAX_SIZE_MB]=250; CONF[EVE_REDIS]=""' 'migrate_run; echo "size=${CONF[EVE_MAX_SIZE_MB]}"'
	[[ "$output" != *"migrate 0.50.0"* ]]
	[[ "$output" == *"size=250"* ]]
}

@test "a Suricata built from source before recipe 2 is built again, one built with it is not" {
	local setup='state_write_value install.finished yes; state_write_value install.version 0.49.0; CONF[SURICATA_SOURCE]=source; CONF[SURICATA_ENABLE]=yes; state_write_value "$SURICATA_BUILT_REF_STATE_KEY" abc123'
	run lib "$setup" 'migrate_rebuilds'
	[[ "$output" == "suricata 1 2 "* ]]
	run lib "$setup; state_write_value build.suricata.recipe 2" 'migrate_rebuilds'
	[ -z "$output" ]
}

@test "a package Suricata is never rebuilt" {
	run lib 'state_write_value install.finished yes; CONF[SURICATA_SOURCE]=oisf; state_write_value "$SURICATA_BUILT_REF_STATE_KEY" abc123' 'migrate_rebuilds'
	[ -z "$output" ]
}

@test "the plan names the migration and the rebuild; nothing to do says so" {
	run lib 'state_write_value install.finished yes; state_write_value install.version 0.49.0; CONF[SURICATA_SOURCE]=source; state_write_value "$SURICATA_BUILT_REF_STATE_KEY" abc123' 'migrate_plan'
	[[ "$output" == *"migration 0.50.0:"* ]]
	[[ "$output" == *"rebuild suricata: recipe 1 -> 2"* ]]
}

@test "a host that is up to date has nothing to migrate" {
	run lib 'state_write_value install.finished yes; state_write_value install.version "$DPISTACK_VERSION"' 'migrate_plan'
	[[ "$output" == *"nothing to migrate"* ]]
}

@test "the step check refuses a Suricata build of an older recipe" {
	grep -q 'build_recipe_have suricata)" == "\$SURICATA_BUILD_RECIPE"' "$REPO_DIR/lib/step_suricata.sh"
	grep -q 'build_recipe_have ndpi)" == "\$NDPI_BUILD_RECIPE"' "$REPO_DIR/lib/step_ndpi.sh"
	grep -q 'build.suricata.recipe' "$REPO_DIR/lib/step_suricata.sh"
	grep -q 'build.ndpi.recipe' "$REPO_DIR/lib/step_ndpi.sh"
}

@test "an install runs the migrations first and records its version last" {
	grep -n 'migrate_run' "$REPO_DIR/install.sh" | head -1
	local run_line rec_line fin_line
	run_line=$(grep -n '^	migrate_run$' "$REPO_DIR/install.sh" | cut -d: -f1)
	rec_line=$(grep -n '^	migrate_record$' "$REPO_DIR/install.sh" | cut -d: -f1)
	fin_line=$(grep -n 'installation finished' "$REPO_DIR/install.sh" | head -1 | cut -d: -f1)
	[ -n "$run_line" ] && [ -n "$rec_line" ]
	[ "$rec_line" -lt "$fin_line" ]
}

@test "the verb migrate --plan prints the plan, another argument is refused" {
	run bash "$REPO_DIR/install.sh" migrate --plan
	[ "$status" -eq 0 ]
	[[ "$output" == *"no finished install"* ]]
	run bash "$REPO_DIR/install.sh" migrate --now
	[ "$status" -eq 2 ]
}

# an installed host in the sandbox that the version 0.49.0 installed and that saved an empty size
old_host() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set EVE_ROTATE=size >/dev/null 2>&1
	grep -rl "^install.version=" "$DPISTACK_ROOT" | head -1 | xargs sed -i 's/^install.version=.*/install.version=0.49.0/'
	sed -i 's/^EVE_MAX_SIZE_MB=.*/EVE_MAX_SIZE_MB=/' "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

@test "a host that is up to date has nothing for migrate to do" {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	run bash "$REPO_DIR/install.sh" migrate --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to migrate"* ]]
}

@test "migrate --yes does the work of an upgrade that was not done: the migration, then the version is recorded" {
	old_host
	run bash "$REPO_DIR/install.sh" migrate --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"migration 0.50.0:"* ]]
	[[ "$output" == *"migrate 0.50.0: EVE_MAX_SIZE_MB was saved empty"* ]]
	grep -q "^EVE_MAX_SIZE_MB=100" "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	grep -rq "^install.version=$(sed -n 's/^DPISTACK_VERSION="\(.*\)"/\1/p' "$REPO_DIR/lib/common.sh")" "$DPISTACK_ROOT"
	run bash "$REPO_DIR/install.sh" migrate --plan
	[[ "$output" == *"nothing to migrate"* ]]
}

@test "migrate without a terminal and without --yes asks nothing and changes nothing" {
	old_host
	run bash "$REPO_DIR/install.sh" migrate </dev/null
	[ "$status" -eq 3 ]
	[[ "$output" == *"use --yes"* ]]
	grep -q "^EVE_MAX_SIZE_MB=$" "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

@test "status says that work is pending, on stderr and not in the JSON, and nothing once it is done" {
	old_host
	run bash -c "DPISTACK_VERBS_ONLY=1 bash '$REPO_DIR/install.sh' status 2>&1 >/dev/null"
	[[ "$output" == *"still has work from an earlier version"* ]]
	[[ "$output" == *"sudo dpistack migrate"* ]]
	run bash -c "DPISTACK_VERBS_ONLY=1 bash '$REPO_DIR/install.sh' status --json 2>&1 >/dev/null"
	[ -z "$output" ]
	bash "$REPO_DIR/install.sh" migrate --yes >/dev/null 2>&1
	run bash -c "DPISTACK_VERBS_ONLY=1 bash '$REPO_DIR/install.sh' status 2>&1 >/dev/null"
	[[ "$output" != *"still has work"* ]]
}

@test "the panel may not run migrate" {
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" migrate --plan
	[ "$status" -eq 2 ]
}
