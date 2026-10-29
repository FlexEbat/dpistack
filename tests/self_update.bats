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
