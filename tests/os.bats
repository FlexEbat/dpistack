#!/usr/bin/env bats
# Covers slice 1 criterion 6: os.sh must tell apt from dnf using
# os-release stubs, including derivatives that only carry ID_LIKE.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

write_os_release() {
	cat >"$DPISTACK_ROOT/etc/os-release"
}

detect_family() {
	bash -c '
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/os.sh"
		os_detect
		echo "$OS_FAMILY"
	' 2>/dev/null
}

@test "ubuntu is apt family" {
	write_os_release <<'EOF'
ID=ubuntu
ID_LIKE=debian
VERSION_ID="24.04"
EOF
	run detect_family
	[ "$status" -eq 0 ]
	[ "$output" = "apt" ]
}

@test "debian is apt family" {
	write_os_release <<'EOF'
ID=debian
VERSION_ID="12"
EOF
	run detect_family
	[ "$status" -eq 0 ]
	[ "$output" = "apt" ]
}

@test "fedora is dnf family" {
	write_os_release <<'EOF'
ID=fedora
VERSION_ID="40"
EOF
	run detect_family
	[ "$status" -eq 0 ]
	[ "$output" = "dnf" ]
}

@test "rhel is dnf family" {
	write_os_release <<'EOF'
ID=rhel
VERSION_ID="9"
EOF
	run detect_family
	[ "$status" -eq 0 ]
	[ "$output" = "dnf" ]
}

@test "rocky is dnf family via ID_LIKE" {
	write_os_release <<'EOF'
ID=rocky
ID_LIKE="rhel centos fedora"
VERSION_ID="9"
EOF
	run detect_family
	[ "$status" -eq 0 ]
	[ "$output" = "dnf" ]
}

@test "alma is dnf family via ID_LIKE" {
	write_os_release <<'EOF'
ID=almalinux
ID_LIKE="rhel centos fedora"
VERSION_ID="9"
EOF
	run detect_family
	[ "$status" -eq 0 ]
	[ "$output" = "dnf" ]
}

@test "unknown distro dies with code 3" {
	write_os_release <<'EOF'
ID=arch
EOF
	run detect_family
	[ "$status" -eq 3 ]
}
