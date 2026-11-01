#!/usr/bin/env bats
# v0.29.1: the unit of a from-source Suricata names a capture mode. Without
# one Suricata prints its usage and exits with 1 (real Debian 13 install).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "the source unit starts Suricata with --af-packet, after the pidfile and with no other mode" {
	run grep '^ExecStart=' "$REPO_DIR/templates/suricata.service.tpl"
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata.pid --af-packet" ]]
	[[ "$output" != *" -i "* ]]
	[[ "$output" != *" -q "* ]]
}

@test "the IPS drop-in still replaces the whole ExecStart with the queue mode, no af-packet" {
	run grep -n 'ExecStart=\$(command -v suricata' "$REPO_DIR/lib/step_suricata.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"-q \${IPS_QUEUE_NUM}"* ]]
	[[ "$output" != *"--af-packet"* ]]
}
