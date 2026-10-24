#!/usr/bin/env bats
# Slice 26 criteria 4 and 5: versionlock on the dnf family, and a missing
# source for the OS release stops the install in preflight with code 3.
# Everything runs against mocks: not verified on a real Rocky, Alma or
# Fedora host (tech.md 18.16).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	CALLS="$(mktemp)"
	export CALLS
	mkdir -p "$DPISTACK_ROOT/etc"
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$CALLS"
}

os_release() {
	printf 'ID=%s\nID_LIKE="%s"\nVERSION_ID="%s"\n' "$1" "$2" "$3" >"$DPISTACK_ROOT/etc/os-release"
}

# fam <script> - every lib loaded, OS detected, mocks first in PATH.
fam() {
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" bash -c "
		cd '$REPO_DIR'
		source lib/paths.sh; source lib/common.sh; source lib/state.sh; source lib/os.sh
		for f in lib/step_*.sh; do source \$f; done
		declare -A CONF=()
		os_detect >/dev/null 2>&1
		$1" 2>&1
}

@test "criterion 4: dnf pins with versionlock and the package carries the version" {
	os_release rocky "rhel centos fedora" 9.4
	run fam 'pkg_spec ntopng 6.2-1; pkg_pin ntopng'
	[ "$status" -eq 0 ]
	[[ "$output" == *"ntopng-6.2-1"* ]]
	grep -q '^dnf install -y python3-dnf-plugin-versionlock$' "$CALLS"
	grep -q '^dnf versionlock add ntopng$' "$CALLS"
}

@test "criterion 4: a pin that cannot install the versionlock plugin fails, it is not skipped" {
	os_release rocky "rhel centos fedora" 9.4
	MOCK_EXIT=1 run fam 'pkg_pin ntopng'
	[ "$status" -ne 0 ]
	! grep -q '^dnf versionlock add' "$CALLS"
}

@test "the COPR chroot follows the OS: epel for the RHEL family, fedora for Fedora" {
	os_release rocky "rhel centos fedora" 9.4
	[ "$(fam copr_chroot)" = "epel-9" ]
	os_release almalinux "rhel centos fedora" 8.10
	[ "$(fam copr_chroot)" = "epel-8" ]
	os_release rhel fedora 10.0
	[ "$(fam copr_chroot)" = "epel-10" ]
	os_release fedora fedora 41
	[ "$(fam copr_chroot)" = "fedora-41" ]
	os_release rocky "rhel centos fedora" ""
	[ -z "$(fam copr_chroot)" ]
}

@test "criterion 5: preflight probes the OISF COPR for this release's chroot" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'CONF[SURICATA_SOURCE]=oisf; step_preflight_reasons' >/dev/null
	grep -q 'curl .*suricata-8.0/repo/epel-9/group_oisf-suricata-8.0-epel-9.repo' "$CALLS"
}

@test "criterion 5: no COPR build for the release gives a preflight reason naming the chroot" {
	os_release rocky "rhel centos fedora" 9.4
	MOCK_CURL_FAIL_MATCH="epel-9" run fam 'CONF[SURICATA_SOURCE]=oisf; step_preflight_reasons'
	[[ "$output" == *"repository OISF COPR for epel-9 is unavailable"* ]]
}

@test "criterion 5: the install stops with code 3 before any step runs" {
	os_release rocky "rhel centos fedora" 9.4
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CURL_FAIL_MATCH="epel-9" MOCK_CALLS_LOG="$CALLS" \
		run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 3 ]
	[[ "$output" == *"OISF COPR for epel-9"* ]]
	if grep -q '^dnf copr enable' "$CALLS"; then false; fi
	! grep -q '^dnf install' "$CALLS"
}

@test "criterion 5: other chroots and sources are not affected by the missing one" {
	os_release rocky "rhel centos fedora" 9.4
	MOCK_CURL_FAIL_MATCH="epel-8" run fam 'CONF[SURICATA_SOURCE]=oisf; step_preflight_reasons'
	[[ "$output" != *"OISF COPR"* ]]
}
