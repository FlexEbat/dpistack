#!/usr/bin/env bats
# dpistack self-update: only a newer release of the project is installed,
# checked, and applied on the saved config.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc" "$DPISTACK_ROOT/fake"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	# a curl that serves the "release server" from files of the test
	cat >"$DPISTACK_ROOT/fake/curl" <<'EOF_CURL'
#!/usr/bin/env bash
out=""
url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-o) out="$2"; shift 2 ;;
	http*) url="$1"; shift ;;
	*) shift ;;
	esac
done
echo "curl $url" >>"$DPISTACK_ROOT/fake/calls"
case "$url" in
*/releases/latest) cat "$DPISTACK_ROOT/fake/latest.json" ;;
*.tar.gz) cp "$DPISTACK_ROOT/fake/release.tar.gz" "$out" ;;
*) exit 0 ;;
esac
EOF_CURL
	chmod +x "$DPISTACK_ROOT/fake/curl"
	PATH="$DPISTACK_ROOT/fake:$REPO_DIR/tests/mocks:$PATH"
	export PATH
	export MOCK_IP_EXISTING_IFACES=enp2s0 MOCK_IP_DEFAULT_IFACE=enp2s0 MOCK_IP_LINK_ROUTE=192.168.10.0/24
	CONF_FILE="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	CUR="$(sed -n 's/^DPISTACK_VERSION="\(.*\)"/\1/p' "$REPO_DIR/lib/common.sh")"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

latest() { printf '{"tag_name":"%s","html_url":"https://github.com/FlexEbat/dpistack/releases/tag/%s"}' "$1" "$1" >"$DPISTACK_ROOT/fake/latest.json"; }

# release <version> - a tarball of this tree that says it is <version>
release() {
	local d="$DPISTACK_ROOT/fake/tree/dpistack-$1"
	mkdir -p "$d"
	tar --exclude=.git -C "$REPO_DIR" -cf - . | tar -xf - -C "$d"
	sed -i "s/^DPISTACK_VERSION=.*/DPISTACK_VERSION=\"$1\"/" "$d/lib/common.sh"
	tar -czf "$DPISTACK_ROOT/fake/release.tar.gz" -C "$DPISTACK_ROOT/fake/tree" "dpistack-$1"
}

base() {
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no "$@"
}

@test "check says an update exists only for a higher version" {
	latest v99.0.0
	run bash "$REPO_DIR/install.sh" self-update --check
	[ "$status" -eq 0 ]
	[[ "$output" == *"99.0.0 is available"* ]]
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" self-update --check
	[[ "$output" == *"is the latest version"* ]]
	run bash "$REPO_DIR/install.sh" self-update check
	[[ "$output" == *'"update_available":false'* ]]
}

@test "a release document without a version tag changes nothing" {
	printf 'not json' >"$DPISTACK_ROOT/fake/latest.json"
	run bash "$REPO_DIR/install.sh" self-update --check
	[ "$status" -ne 0 ]
	[[ "$output" == *"no usable version tag"* ]]
}

@test "apply with no newer release downloads nothing" {
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" self-update apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"nothing to do"* ]]
	run grep -c "tar.gz" "$DPISTACK_ROOT/fake/calls"
	[ "$output" = "0" ]
}

@test "apply installs the new release on the saved config and keeps the values" {
	run base --set STATS_INTERVAL_SEC=45
	[ "$status" -eq 0 ]
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" self-update apply
	[ "$status" -eq 0 ]
	[[ "$output" == *"installing 99.0.0 on the saved config"* ]]
	grep -q "^STATS_INTERVAL_SEC=45" "$CONF_FILE"
	grep -q 'DPISTACK_VERSION="99.0.0"' "$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/common.sh"
}

@test "an archive that does not carry the announced version is refused" {
	latest v99.0.0
	release 98.0.0
	run bash "$REPO_DIR/install.sh" self-update apply
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not carry the version 99.0.0"* ]]
}

@test "an archive with a path outside the target is refused" {
	latest v99.0.0
	mkdir -p "$DPISTACK_ROOT/fake/x"
	echo x >"$DPISTACK_ROOT/fake/x/file"
	tar -czf "$DPISTACK_ROOT/fake/release.tar.gz" -C "$DPISTACK_ROOT/fake/x" --transform 's#^#../#' file
	run bash "$REPO_DIR/install.sh" self-update apply
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsafe path"* ]]
}

@test "run refuses when there is no newer release" {
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" self-update run
	[ "$status" -eq 3 ]
	[[ "$output" == *"no newer release"* ]]
}

@test "apply on a lan install does not stop at the access confirmation" {
	run base --set ACCESS_MODE=lan --set ACCESS_CONFIRM=yes
	[ "$status" -eq 0 ]
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" self-update apply
	[ "$status" -eq 0 ]
	[[ "$output" != *"needs --set ACCESS_CONFIRM=yes"* ]]
	grep -q 'DPISTACK_VERSION="99.0.0"' "$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/common.sh"
}

@test "apply does not confirm an access mode that was edited after the last apply" {
	run base
	[ "$status" -eq 0 ]
	sed -i 's/^ACCESS_MODE=.*/ACCESS_MODE=lan/' "$CONF_FILE"
	grep -q '^ACCESS_MODE=lan' "$CONF_FILE"
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" self-update apply
	[ "$status" -eq 2 ]
	[[ "$output" == *"needs --set ACCESS_CONFIRM=yes"* ]]
}

@test "update says so when this is the latest version, and --check only reports" {
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" update
	[ "$status" -eq 0 ]
	[[ "$output" == *"is the latest version"* ]]
	latest v99.0.0
	run bash "$REPO_DIR/install.sh" update --check
	[ "$status" -eq 0 ]
	[[ "$output" == *"99.0.0 is available"* ]]
	run grep -c "tar.gz" "$DPISTACK_ROOT/fake/calls"
	[ "$output" = "0" ]
}

@test "update --dry-run downloads the release, shows what it will do and installs nothing" {
	run base
	[ "$status" -eq 0 ]
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" update --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"what 99.0.0 does to this host"* ]]
	[[ "$output" == *"installed: "* ]]
	run grep -c 'DPISTACK_VERSION="99.0.0"' "$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/common.sh"
	[ "$output" = "0" ]
}

@test "update without a terminal and without --yes asks nothing and changes nothing" {
	run base
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" update </dev/null
	[ "$status" -eq 3 ]
	[[ "$output" == *"use --yes"* ]]
	run grep -c 'DPISTACK_VERSION="99.0.0"' "$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/common.sh"
	[ "$output" = "0" ]
}

@test "update --yes installs the release on the saved config and records the version" {
	run base --set STATS_INTERVAL_SEC=45
	[ "$status" -eq 0 ]
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" update --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"installing 99.0.0 on the saved config"* ]]
	grep -q "^STATS_INTERVAL_SEC=45" "$CONF_FILE"
	grep -q 'DPISTACK_VERSION="99.0.0"' "$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/common.sh"
	grep -rq "^install.version=99.0.0" "$DPISTACK_ROOT"
}

@test "update refuses an option it does not know and the panel may not use it" {
	run bash "$REPO_DIR/install.sh" update --now
	[ "$status" -eq 2 ]
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" update --check
	[ "$status" -eq 2 ]
}

@test "the update from an older version runs the migrations of the new one" {
	run base --set EVE_ROTATE=size
	[ "$status" -eq 0 ]
	# this host was installed by 0.49.0 and saved an empty size
	grep -rl "^install.version=" "$DPISTACK_ROOT" | head -1 | xargs sed -i 's/^install.version=.*/install.version=0.49.0/'
	sed -i 's/^EVE_MAX_SIZE_MB=.*/EVE_MAX_SIZE_MB=/' "$CONF_FILE"
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" update --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"migrate 0.50.0: EVE_MAX_SIZE_MB was saved empty"* ]]
	grep -q "^EVE_MAX_SIZE_MB=100" "$CONF_FILE"
}

@test "update on the latest version still does the work an earlier upgrade left, by itself" {
	run base --set EVE_ROTATE=size
	[ "$status" -eq 0 ]
	grep -rl "^install.version=" "$DPISTACK_ROOT" | head -1 | xargs sed -i 's/^install.version=.*/install.version=0.49.0/'
	sed -i 's/^EVE_MAX_SIZE_MB=.*/EVE_MAX_SIZE_MB=/' "$CONF_FILE"
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" update --check
	[[ "$output" == *"still has work from an earlier version"* ]]
	grep -q "^EVE_MAX_SIZE_MB=$" "$CONF_FILE"
	run bash "$REPO_DIR/install.sh" update --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"migrate 0.50.0: EVE_MAX_SIZE_MB was saved empty"* ]]
	grep -q "^EVE_MAX_SIZE_MB=100" "$CONF_FILE"
}

@test "self-update plan prints what the newest release will do, installs nothing, and says when there is none" {
	run base
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" self-update plan
	[ "$status" -eq 0 ]
	[[ "$output" == *"there is no newer release"* ]]
	latest v99.0.0
	release 99.0.0
	run bash "$REPO_DIR/install.sh" self-update plan
	[ "$status" -eq 0 ]
	[[ "$output" == *"dpistack 99.0.0 will do this on this host:"* ]]
	[[ "$output" == *"installed: "* ]]
	run grep -c 'DPISTACK_VERSION="99.0.0"' "$DPISTACK_ROOT/usr/local/lib/dpistack/installer/lib/common.sh"
	[ "$output" = "0" ]
}

@test "the panel may run self-update plan (it only reads), and the error text names it" {
	latest v99.0.0
	release 99.0.0
	DPISTACK_CALLER=panel run bash "$REPO_DIR/install.sh" self-update plan
	[ "$status" -eq 0 ]
	run bash "$REPO_DIR/install.sh" self-update nonsense
	[ "$status" -eq 2 ]
	[[ "$output" == *"plan"* ]]
}

@test "run starts a repair when the installer is the newest but the panel runs an older version" {
	latest "v$CUR"
	export MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	run bash "$REPO_DIR/install.sh" self-update run --panel-version 0.0.1
	[ "$status" -eq 0 ]
	[[ "$output" == *"repair started"* ]]
	grep -q "systemd-run .*self-update apply --repair" "$MOCK_CALLS_LOG"
}

@test "run does not repair when the panel runs the installed version" {
	latest "v$CUR"
	run bash "$REPO_DIR/install.sh" self-update run --panel-version "$CUR"
	[ "$status" -eq 3 ]
	[[ "$output" == *"no newer release"* ]]
}

@test "a repair is refused, naming the file, when a drop-in pins the command line of the panel" {
	latest "v$CUR"
	mkdir -p "$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service.d"
	printf '[Service]\nExecStart=\nExecStart=/usr/local/bin/dpistack-panel -version 0.0.1\n' \
		>"$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service.d/old.conf"
	export MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	run bash "$REPO_DIR/install.sh" self-update run --panel-version 0.0.1
	[ "$status" -eq 1 ]
	[[ "$output" == *"old.conf"* && "$output" == *"replaces its command line"* ]]
	! grep -q "systemd-run" "$MOCK_CALLS_LOG" 2>/dev/null
}

@test "a drop-in that only resets ExecStart does not block a repair" {
	latest "v$CUR"
	mkdir -p "$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service.d"
	printf '[Service]\nExecStart=\n' >"$DPISTACK_ROOT/etc/systemd/system/dpistack-panel.service.d/reset.conf"
	run bash "$REPO_DIR/install.sh" self-update run --panel-version 0.0.1
	[ "$status" -eq 0 ]
	[[ "$output" == *"repair started"* ]]
}

@test "run takes only a plain version as the panel version" {
	latest v99.0.0
	# the dispatcher stops an argument with shell characters before the verb sees it
	run bash "$REPO_DIR/install.sh" self-update run --panel-version '1.2.3; rm -rf /'
	[ "$status" -eq 5 ]
	run bash "$REPO_DIR/install.sh" self-update run --panel-version latest
	[ "$status" -eq 2 ]
	run bash "$REPO_DIR/install.sh" self-update run --bogus
	[ "$status" -eq 2 ]
}

@test "apply --repair installs the same release again and restarts the panel" {
	run base
	[ "$status" -eq 0 ]
	latest "v$CUR"
	release "$CUR"
	export MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	run bash "$REPO_DIR/install.sh" self-update apply --repair
	[ "$status" -eq 0 ]
	[[ "$output" == *"installing $CUR"* ]]
	run bash "$REPO_DIR/install.sh" self-update apply
	[[ "$output" == *"nothing to do"* ]]
}
