#!/usr/bin/env bats
# Covers slice 3 criteria 2, 3, 4, 5 (per tech.md's own note, on the
# mocked suricata-update from tests/mocks).

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
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	RULESET="$DPISTACK_ROOT/var/lib/suricata/rules/suricata.rules"
	TIMER_FILE="$DPISTACK_ROOT/etc/systemd/system/dpistack-rules.timer"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG"
}

install_base() {
	bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "criterion 2: RULES_UPDATE_CALENDAR=daily sets OnCalendar in the timer" {
	run install_base --set RULES_UPDATE_CALENDAR=daily
	[ "$status" -eq 0 ]
	[ -f "$TIMER_FILE" ]
	grep -q '^OnCalendar=daily$' "$TIMER_FILE"
}

@test "criterion 3: a failed suricata -T after update keeps the old ruleset and fails" {
	mkdir -p "$(dirname "$RULESET")"
	echo "# old trusted ruleset" >"$RULESET"

	MOCK_SURICATA_UPDATE_FAIL=1 run install_base
	[ "$status" -ne 0 ]
	[ "$(cat "$RULESET")" = "# old trusted ruleset" ]
}

@test "criterion 4: RULES_UPDATE=off does not create a timer" {
	run install_base --set RULES_UPDATE=off
	[ "$status" -eq 0 ]
	[ ! -f "$TIMER_FILE" ]
}

@test "criterion 4: RULES_UPDATE=off removes a pre-existing timer" {
	run install_base
	[ "$status" -eq 0 ]
	[ -f "$TIMER_FILE" ]

	run install_base --set RULES_UPDATE=off
	[ "$status" -eq 0 ]
	[ ! -f "$TIMER_FILE" ]
}

@test "criterion 5: a custom URL in RULES_URLS is registered and lands in the set" {
	run install_base --set RULES_URLS=https://example.com/my-custom.rules
	[ "$status" -eq 0 ]
	run grep -c "add-source.*https://example.com/my-custom.rules" "$MOCK_CALLS_LOG"
	[ "$output" = "1" ]
	[ -f "$RULESET" ]
	grep -q "add-source" "$RULESET"
}
