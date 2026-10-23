#!/usr/bin/env bats
# dpistack on distributions that are not apt or dnf: openSUSE (zypper), Arch
# (pacman) and any other Linux with systemd (generic). The components run in
# Docker there; the package managers are mocks.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc" "$DPISTACK_ROOT/run/systemd/system"
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

os_release() {
	printf '%s\n' "$@" >"$DPISTACK_ROOT/etc/os-release"
}

ALLDOCKER=(--set SURICATA_RUNTIME=docker --set EVEBOX_RUNTIME=docker --set NTOPNG_RUNTIME=docker --set NDPI_ENABLE=no)

inst() {
	bash "$REPO_DIR/install.sh" install -y "$@"
}

@test "native components on a family without their packages stop in preflight with the flags to set" {
	os_release ID=arch
	run inst --dry-run
	[ "$status" -eq 3 ]
	[[ "$output" == *"SURICATA_RUNTIME=native: на arch пакетов компонента установщик не ставит, задайте --set SURICATA_RUNTIME=docker"* ]]
	[[ "$output" == *"EVEBOX_RUNTIME"* && "$output" == *"NTOPNG_RUNTIME"* ]]
}

@test "arch, opensuse and an unnamed systemd distro install with every component in docker" {
	for rel in "ID=arch" "ID=opensuse-leap" "ID=void"; do
		rm -rf "$DPISTACK_ROOT/opt" "$DPISTACK_ROOT/etc/dpistack"
		os_release "$rel"
		run inst "${ALLDOCKER[@]}"
		if [ "$status" -ne 0 ]; then
			echo "$rel: $output" >&2
			return 1
		fi
		grep -q '^  suricata:$' "$COMPOSE"
		grep -q '^  evebox:$' "$COMPOSE"
		grep -q '^  ntopng:$' "$COMPOSE"
	done
}

@test "the package manager of the family is the one that is called" {
	os_release ID=opensuse-leap
	MOCK_NEED_TOOLS=1 run inst "${ALLDOCKER[@]}"
	[ "$status" -eq 0 ]
	run grep -E '^(apt-get|dnf|pacman) ' "$MOCK_CALLS_LOG"
	[ "$status" -ne 0 ]
}

@test "the whole stack in docker, panel included, on a distro that has no package manager of the project" {
	os_release ID=void
	run inst "${ALLDOCKER[@]}" --set PANEL_RUNTIME=docker
	[ "$status" -eq 0 ]
	grep -q '^  panel:$' "$COMPOSE"
}

@test "a system without systemd is refused with code 3 and a clear message" {
	rm -rf "$DPISTACK_ROOT/run/systemd"
	os_release ID=alpine
	run inst "${ALLDOCKER[@]}"
	[ "$status" -eq 3 ]
	[[ "$output" == *"нужен systemd"* ]]
}
