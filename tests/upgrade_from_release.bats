#!/usr/bin/env bats
# An upgrade from a REAL earlier release (tech.md 18.58, slice 52): the tagged
# archive of the previous version is installed in the sandbox, then this tree
# migrates it. The synthetic old states of migrate.bats and self_update.bats
# cannot show a break between two real releases. Skipped unless
# DPISTACK_UPGRADE_FROM names the tag (the CI job `upgrade` sets it); GH_TOKEN
# is used for the download when it is set (a private repository).

setup() {
	[ -n "${DPISTACK_UPGRADE_FROM:-}" ] || skip "set DPISTACK_UPGRADE_FROM=vX.Y.Z to run (the CI job upgrade does)"
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	CUR=$(sed -n 's/^DPISTACK_VERSION="\(.*\)"/\1/p' "$REPO_DIR/lib/common.sh")
	PREV_TAG="$DPISTACK_UPGRADE_FROM"
	PREV_VER="${PREV_TAG#v}"
	PREV_DIR="$DPISTACK_ROOT/prev"
	mkdir -p "$PREV_DIR"
	local auth=()
	[ -z "${GH_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $GH_TOKEN")
	command curl -fsSL "${auth[@]}" -o "$DPISTACK_ROOT/prev.tar.gz" \
		"https://api.github.com/repos/FlexEbat/dpistack/tarball/$PREV_TAG"
	tar -xzf "$DPISTACK_ROOT/prev.tar.gz" -C "$PREV_DIR" --strip-components=1
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	export MOCK_IP_EXISTING_IFACES=enp2s0 MOCK_IP_DEFAULT_IFACE=enp2s0 MOCK_IP_LINK_ROUTE=192.168.10.0/24
}

teardown() {
	[ -z "${DPISTACK_ROOT:-}" ] || rm -rf "$DPISTACK_ROOT"
}

@test "the previous release says it is the version that was asked for" {
	grep -q "^DPISTACK_VERSION=\"$PREV_VER\"" "$PREV_DIR/lib/common.sh"
	[ "$PREV_VER" != "$CUR" ]
}

@test "a host installed by the previous release is migrated by this tree, then is up to date and answers status" {
	run bash "$PREV_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set EVE_ROTATE=size
	[ "$status" -eq 0 ]

	# what this version says it will do
	run bash "$REPO_DIR/install.sh" migrate --plan
	[ "$status" -eq 0 ]
	[[ "$output" == *"this version: $CUR"* ]]

	# doing it ends in a finished install of this version
	run bash "$REPO_DIR/install.sh" migrate --yes
	[ "$status" -eq 0 ]
	[[ "$output" == *"installation finished"* || "$output" == *"nothing to migrate"* ]]
	# a release with no migration of its own (a patch release) has nothing to do,
	# so no install runs and the recorded version stays the old one
	if [[ "$output" == *"installation finished"* ]]; then
		grep -rq "^install.version=$CUR" "$DPISTACK_ROOT"
	fi

	# nothing is left, the config is valid and status is JSON
	run bash "$REPO_DIR/install.sh" migrate --plan
	[[ "$output" == *"nothing to migrate"* ]]
	run bash "$REPO_DIR/install.sh" settings list --json
	[ "$status" -eq 0 ]
	jq -e '.keys | length > 0' <<<"$output" >/dev/null
	run bash -c "DPISTACK_VERBS_ONLY=1 bash '$REPO_DIR/install.sh' status --json"
	[ "$status" -eq 0 ]
	jq -e . <<<"$output" >/dev/null
}

@test "the same upgrade through dpistack update --yes from a release of this tree" {
	run bash "$PREV_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no
	[ "$status" -eq 0 ]
	# this tree is "published" as the next release: a curl that serves it
	mkdir -p "$DPISTACK_ROOT/fake/tree/dpistack-$CUR"
	tar --exclude=.git --exclude=node_modules -C "$REPO_DIR" -cf - . | tar -xf - -C "$DPISTACK_ROOT/fake/tree/dpistack-$CUR"
	tar -czf "$DPISTACK_ROOT/fake/release.tar.gz" -C "$DPISTACK_ROOT/fake/tree" "dpistack-$CUR"
	printf '{"tag_name":"v%s","html_url":"https://github.com/FlexEbat/dpistack/releases/tag/v%s"}' "$CUR" "$CUR" >"$DPISTACK_ROOT/fake/latest.json"
	mkdir -p "$DPISTACK_ROOT/fake"
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
case "$url" in
*/releases/latest) cat "$DPISTACK_ROOT/fake/latest.json" ;;
*.tar.gz) cp "$DPISTACK_ROOT/fake/release.tar.gz" "$out" ;;
*) exit 0 ;;
esac
EOF_CURL
	chmod +x "$DPISTACK_ROOT/fake/curl"
	PATH="$DPISTACK_ROOT/fake:$PATH"
	export PATH
	run bash "$PREV_DIR/install.sh" update --yes
	# the previous release has no `update` verb before 0.50.0; its own
	# self-update is the path then
	if [ "$status" -ne 0 ]; then
		run bash "$PREV_DIR/install.sh" self-update apply
	fi
	[ "$status" -eq 0 ]
	grep -rq "^install.version=$CUR" "$DPISTACK_ROOT"
}
