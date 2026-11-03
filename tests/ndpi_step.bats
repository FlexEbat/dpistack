#!/usr/bin/env bats
# Covers slice 4 criteria 3 and 6 (per tech.md's own test scope for
# this slice). git/autogen.sh/configure/make are real, relative-path
# invocations inside a cloned tree, not PATH-resolved commands, so
# they can't be intercepted the way apt-get/systemctl are; criterion 6
# (idempotency) is exercised directly against step_ndpi_check's state
# logic instead of a full build.

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

@test "criterion 3: NDPI_ENABLE=yes without SURICATA_SOURCE=source and no ndpi.so exits 2" {
	run bash "$REPO_DIR/install.sh" install -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=yes
	[ "$status" -eq 2 ]
	[[ "$output" == *"SURICATA_SOURCE=source"* ]]
}

@test "criterion 3: NDPI_ENABLE=yes with SURICATA_SOURCE=oisf passes once ndpi.so exists" {
	mkdir -p "$(dirname "$DPISTACK_ROOT/usr/lib/suricata/ndpi.so")"
	touch "$DPISTACK_ROOT/usr/lib/suricata/ndpi.so"
	run bash "$REPO_DIR/install.sh" install --dry-run -y \
		--set SURICATA_SOURCE=oisf --set NDPI_ENABLE=yes
	[ "$status" -eq 0 ]
}

@test "criterion 6: a second check does not report work needed for the same already-built version" {
	mkdir -p "$DPISTACK_ROOT/usr/local/lib"
	touch "$DPISTACK_ROOT/usr/local/lib/libndpi.so"
	# The state holds the built commit; the pinned tag is compared as the
	# commit it names.
	src="$DPISTACK_ROOT/usr/local/src/dpistack-ndpi"
	mkdir -p "$src"
	git -C "$src" init -q
	git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
	git -C "$src" tag v4.14
	sha="$(git -C "$src" rev-parse HEAD)"

	run bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/state.sh"
		config_reset
		config_load_defaults
		CONF[NDPI_ENABLE]="yes"
		CONF[NDPI_SOURCE]="source"
		CONF[NDPI_VERSION]="v4.14"
		source "'"$REPO_DIR"'/lib/step_ndpi.sh"
		state_write_value "ndpi.built_ref" "'"$sha"'"
		step_ndpi_check && echo "ALREADY_DONE"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"ALREADY_DONE"* ]]
}

@test "criterion 6: a different NDPI_VERSION than what was built is reported as work needed" {
	mkdir -p "$DPISTACK_ROOT/usr/local/lib"
	touch "$DPISTACK_ROOT/usr/local/lib/libndpi.so"

	run bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		SCRIPT_DIR="'"$REPO_DIR"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		source "'"$REPO_DIR"'/lib/schema.sh"
		source "'"$REPO_DIR"'/lib/config.sh"
		source "'"$REPO_DIR"'/lib/state.sh"
		config_reset
		config_load_defaults
		CONF[NDPI_ENABLE]="yes"
		CONF[NDPI_SOURCE]="source"
		CONF[NDPI_VERSION]="v4.14"
		source "'"$REPO_DIR"'/lib/step_ndpi.sh"
		state_write_value "ndpi.built_ref" "v4.12"
		step_ndpi_check && echo "ALREADY_DONE" || echo "NEEDS_BUILD"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"NEEDS_BUILD"* ]]
}

# v0.30.1: a clone of nDPI died on a real install with "HTTP/2 stream was not
# closed cleanly" and stopped the install. The clone is repeated, over HTTP/1.1.
@test "git_clone_retry repeats a failed clone and succeeds on the second try" {
	fakebin="$(mktemp -d)"
	cat >"$fakebin/git" <<FAKE
#!/bin/bash
echo "git \$*" >>"$fakebin/calls"
if [[ ! -e "$fakebin/failed" ]]; then
	touch "$fakebin/failed"
	mkdir -p "\${@: -1}"
	exit 128
fi
mkdir -p "\${@: -1}/.git"
FAKE
	chmod +x "$fakebin/git"
	run env PATH="$fakebin:$PATH" DPISTACK_RETRY_DELAY=0 bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		git_clone_retry https://example.invalid/ndpi.git "'"$DPISTACK_ROOT"'/src"
		echo "RC=$?"
	'
	[ "$status" -eq 0 ]
	[[ "$output" == *"RC=0"* ]]
	[ "$(grep -c 'clone' "$fakebin/calls")" -eq 2 ]
	grep -q -- '-c http.version=HTTP/1.1 clone' "$fakebin/calls"
	[ -d "$DPISTACK_ROOT/src/.git" ]
	rm -rf "$fakebin"
}

@test "git_clone_retry gives up after three tries and returns the git status" {
	fakebin="$(mktemp -d)"
	printf '#!/bin/bash\necho x >>"%s/calls"\nexit 128\n' "$fakebin" >"$fakebin/git"
	chmod +x "$fakebin/git"
	run env PATH="$fakebin:$PATH" DPISTACK_RETRY_DELAY=0 bash -c '
		DPISTACK_ROOT="'"$DPISTACK_ROOT"'"
		source "'"$REPO_DIR"'/lib/paths.sh"
		source "'"$REPO_DIR"'/lib/common.sh"
		git_clone_retry https://example.invalid/ndpi.git "'"$DPISTACK_ROOT"'/src"
	'
	[ "$status" -eq 128 ]
	[ "$(wc -l <"$fakebin/calls")" -eq 3 ]
	rm -rf "$fakebin"
}
