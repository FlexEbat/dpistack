#!/usr/bin/env bats
# Slice 30 (tech.md 17): dpistack-install.sh, the installer in one file.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	BUNDLE="$REPO_DIR/dpistack-install.sh"
	WORK="$(mktemp -d)"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
}

teardown() {
	rm -rf "$WORK"
	rm -f "$MOCK_CALLS_LOG"
}

# a root for one run of the installer, with the os-release the mocks expect
new_root() {
	local r
	r="$(mktemp -d -p "$WORK")"
	mkdir -p "$r/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$r/etc/os-release"
	echo "$r"
}

# a copy of what scripts/bundle.sh reads, to change without touching the repo
copy_sources() {
	local dest="$1"
	mkdir -p "$dest"
	tar -C "$REPO_DIR" -cf - install.sh lib templates bin scripts tests/data | tar -C "$dest" -xf -
}

strip_times() { sed 's/^[0-9T:-]*Z //'; }

@test "criterion 2: the bundle passes bash -n and shellcheck" {
	bash -n "$BUNDLE"
	if command -v shellcheck >/dev/null 2>&1; then
		LANG=C.utf8 LC_ALL=C.utf8 shellcheck -x "$BUNDLE"
	fi
}

@test "criterion 3: --check passes on what the sources produce" {
	run bash "$REPO_DIR/scripts/bundle.sh" --check
	[ "$status" -eq 0 ]
}

@test "criterion 3: --check fails when a source changed and the bundle was not rebuilt" {
	copy_sources "$WORK/src"
	cp "$BUNDLE" "$WORK/src/dpistack-install.sh"
	run bash "$WORK/src/scripts/bundle.sh" --check
	[ "$status" -eq 0 ]
	echo "# changed" >>"$WORK/src/lib/ips.sh"
	run bash "$WORK/src/scripts/bundle.sh" --check
	[ "$status" -eq 1 ]
	[[ "$output" == *"out of date"* ]]
	# rebuilding brings it back
	bash "$WORK/src/scripts/bundle.sh" >/dev/null
	run bash "$WORK/src/scripts/bundle.sh" --check
	[ "$status" -eq 0 ]
}

@test "criterion 3: a missing bundle fails --check" {
	copy_sources "$WORK/src"
	run bash "$WORK/src/scripts/bundle.sh" --check
	[ "$status" -eq 1 ]
	[[ "$output" == *"does not exist"* ]]
}

@test "the build is the same twice: no times, no paths" {
	copy_sources "$WORK/a"
	copy_sources "$WORK/b"
	bash "$WORK/a/scripts/bundle.sh" >/dev/null
	bash "$WORK/b/scripts/bundle.sh" >/dev/null
	cmp "$WORK/a/dpistack-install.sh" "$WORK/b/dpistack-install.sh"
	cmp "$WORK/a/dpistack-install.sh" "$BUNDLE"
}

@test "a source with the heredoc terminator, or without a final newline, stops the build" {
	copy_sources "$WORK/src"
	printf 'x\nDPISTACK_BUNDLE_END\ny\n' >"$WORK/src/templates/bad.tpl"
	run bash "$WORK/src/scripts/bundle.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"terminator"* ]]
	rm "$WORK/src/templates/bad.tpl"
	printf 'no newline' >"$WORK/src/templates/bad.tpl"
	run bash "$WORK/src/scripts/bundle.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no newline"* ]]
}

@test "criterion 1: --help is the same as the modular one" {
	# --help prints the usage and exits 2, in both
	run bash "$REPO_DIR/install.sh" --help
	s1=$status
	echo "$output" >"$WORK/h1"
	run bash "$BUNDLE" --help
	[ "$status" -eq "$s1" ]
	[ "$output" = "$(cat "$WORK/h1")" ]
	[ -n "$output" ]
}

@test "criterion 1: install --dry-run -y is the same as the modular one" {
	DPISTACK_ROOT="$(new_root)"
	export DPISTACK_ROOT
	bash "$REPO_DIR/install.sh" install --dry-run -y 2>&1 | strip_times >"$WORK/d1"
	bash "$BUNDLE" install --dry-run -y 2>&1 | strip_times >"$WORK/d2"
	cmp "$WORK/d1" "$WORK/d2"
	grep -q 'dry-run: план показан' "$WORK/d2"
}

@test "criterion 1: the exit code of the bundle is the one of install.sh" {
	DPISTACK_ROOT="$(new_root)"
	export DPISTACK_ROOT
	run bash "$BUNDLE" install --dry-run --set NOSUCHKEY=1
	[ "$status" -eq 2 ]
	run bash "$BUNDLE" bogus-command
	[ "$status" -eq 2 ]
}

@test "a real install from the bundle leaves the same installer copy as the modular one" {
	root_a="$(new_root)"
	root_b="$(new_root)"
	DPISTACK_ROOT="$root_a" bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	DPISTACK_ROOT="$root_b" bash "$BUNDLE" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	diff -r "$root_a/usr/local/lib/dpistack/installer" "$root_b/usr/local/lib/dpistack/installer"
	# the binary pcap came through the base64 heredoc intact
	cmp "$REPO_DIR/tests/data/bittorrent.pcap" "$root_b/usr/local/lib/dpistack/installer/tests/data/bittorrent.pcap"
	[ -x "$root_b/usr/local/sbin/dpistack-ctl" ]
	run env DPISTACK_ROOT="$root_b" "$root_b/usr/local/sbin/dpistack-ctl" version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "the temporary directory is removed when the bundle exits" {
	DPISTACK_ROOT="$(new_root)"
	export DPISTACK_ROOT
	TMPDIR="$WORK/tmp"
	export TMPDIR
	mkdir -p "$TMPDIR"
	bash "$BUNDLE" install --dry-run -y >/dev/null 2>&1
	[ -z "$(ls -A "$TMPDIR")" ]
}

@test "the panel is looked for next to the bundle, not in the unpacked directory" {
	DPISTACK_ROOT="$(new_root)"
	export DPISTACK_ROOT
	mkdir -p "$WORK/rel"
	cp "$BUNDLE" "$WORK/rel/dpistack-install.sh"
	run bash "$WORK/rel/dpistack-install.sh" install --dry-run -y --set PANEL_SOURCE=prebuilt
	[ "$status" -eq 3 ]
	[[ "$output" == *"нет готового бинарника"* ]]
	printf '#!/bin/sh\n' >"$WORK/rel/dpistack-panel-linux-amd64"
	printf '#!/bin/sh\n' >"$WORK/rel/dpistack-panel-linux-arm64"
	chmod +x "$WORK/rel"/dpistack-panel-linux-*
	run bash "$WORK/rel/dpistack-install.sh" install --dry-run -y --set PANEL_SOURCE=prebuilt
	[ "$status" -eq 0 ]
	[[ "$output" == *"PANEL_SOURCE=prebuilt"* ]]
}

@test "read from a pipe, the bundle takes the current directory as its origin" {
	DPISTACK_ROOT="$(new_root)"
	export DPISTACK_ROOT
	run bash "$BUNDLE" --help
	s1=$status
	expected="$output"
	run bash -c "cat '$BUNDLE' | bash -s -- --help"
	[ "$status" -eq "$s1" ]
	[ "$output" = "$expected" ]
	[ -n "$output" ]
}

@test "the gate rebuilds nothing: it checks the bundle" {
	grep -q 'scripts/bundle.sh --check' "$REPO_DIR/scripts/gate.sh"
	grep -q 'dpistack-install.sh' "$REPO_DIR/scripts/gate.sh"
}
