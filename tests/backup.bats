#!/usr/bin/env bats
# Slice 36: `dpistack backup create|list|verify|restore` (tech.md 4.5, 18.36).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_CALLS_LOG="$DPISTACK_ROOT/calls.log"
	export MOCK_CALLS_LOG
	E="$DPISTACK_ROOT/etc"
	mkdir -p "$E/dpistack" "$E/suricata/rules" "$E/evebox"
	printf 'ACCESS_MODE=localhost\n' >"$E/dpistack/dpistack.conf"
	printf '{"users":[{"name":"admin","role":"admin","hash":"h"}]}\n' >"$E/dpistack/users.json"
	chmod 0640 "$E/dpistack/users.json"
	printf 'vars: {}\n' >"$E/suricata/suricata.yaml"
	printf 'alert tcp any any -> any any (msg:"one"; sid:1000001; rev:1;)\n' >"$E/suricata/rules/local.rules"
	printf 'sid1\n' >"$E/suricata/disable.conf"
	printf 'a: 1\n' >"$E/evebox/evebox.yaml"
	ARC_DIR="$DPISTACK_ROOT/var/lib/dpistack/archives"
	printf 'METRICS_TOKEN=tokentokentoken1234\n' >"$E/dpistack/secrets.conf"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

make_backup() {
	run "$CTL" backup create
	[ "$status" -eq 0 ]
	ARC="$(printf '%s\n' "$output" | head -n 1)"
	[ -f "$ARC" ]
}

@test "create writes one archive with a manifest of the files that exist" {
	make_backup
	[[ "$ARC" == "$ARC_DIR"/dpistack-backup-*.tar.gz ]]
	run tar -tzf "$ARC"
	[[ "$output" == *manifest.json* ]]
	[[ "$output" == *files/dpistack.conf* ]]
	[[ "$output" == *files/users.json* ]]
	[[ "$output" != *files/modify.conf* ]]
	[ "$(tar -xzOf "$ARC" manifest.json | jq -r '.files | length')" -eq 6 ]
	[ "$(tar -xzOf "$ARC" manifest.json | jq -r '.program')" = "$(bash "$REPO_DIR/install.sh" version)" ]
}

@test "create leaves secrets.conf out" {
	make_backup
	run tar -tzf "$ARC"
	[[ "$output" != *secrets* ]]
	[ "$(tar -xzOf "$ARC" | grep -c tokentoken)" -eq 0 ]
}

@test "create --out writes the named file and refuses to overwrite" {
	run "$CTL" backup create --out "$DPISTACK_ROOT/mine.tar.gz"
	[ "$status" -eq 0 ]
	[ -f "$DPISTACK_ROOT/mine.tar.gz" ]
	run "$CTL" backup create --out "$DPISTACK_ROOT/mine.tar.gz"
	[ "$status" -eq 1 ]
}

@test "create with nothing to back up fails" {
	rm -rf "$E"
	run "$CTL" backup create
	[ "$status" -eq 1 ]
	[[ "$output" == *"nothing to back up"* ]]
}

@test "the panel cannot choose a path: --out and a path to an archive are refused" {
	run env DPISTACK_CALLER=panel "$CTL" backup create --out "$DPISTACK_ROOT/x.tar.gz"
	[ "$status" -eq 5 ]
	make_backup
	run env DPISTACK_CALLER=panel "$CTL" backup verify "$ARC"
	[ "$status" -eq 5 ]
	run env DPISTACK_CALLER=panel "$CTL" backup verify "../${ARC##*/}"
	[ "$status" -eq 5 ]
	run env DPISTACK_CALLER=panel "$CTL" backup verify "${ARC##*/}"
	[ "$status" -eq 0 ]
}

@test "list shows the archives, newest first, as text and as JSON" {
	make_backup
	sleep 1
	run "$CTL" backup create
	[ "$status" -eq 0 ]
	run "$CTL" backup list --json
	[ "$status" -eq 0 ]
	[ "$(jq 'length' <<<"$output")" -eq 2 ]
	[ "$(jq -r '.[0].files' <<<"$output")" -eq 6 ]
	run "$CTL" backup list
	[ "$status" -eq 0 ]
	[[ "$output" == *"6 files"* ]]
}

@test "list of an empty directory is an empty list" {
	run "$CTL" backup list --json
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "verify passes for a fresh archive" {
	make_backup
	run "$CTL" backup verify "$ARC"
	[ "$status" -eq 0 ]
	[[ "$output" == ok:* ]]
}

@test "verify fails when one byte of a file changes" {
	make_backup
	work="$(mktemp -d)"
	tar -xzf "$ARC" -C "$work"
	printf 'X' >>"$work/files/suricata.yaml"
	tar -czf "$DPISTACK_ROOT/bad.tar.gz" -C "$work" manifest.json files
	run "$CTL" backup verify "$DPISTACK_ROOT/bad.tar.gz"
	[ "$status" -eq 3 ]
	[[ "$output" == *"checksum does not match"* ]]
	rm -rf "$work"
}

@test "verify refuses a file that is not in the manifest" {
	make_backup
	work="$(mktemp -d)"
	tar -xzf "$ARC" -C "$work"
	printf 'x\n' >"$work/files/modify.conf"
	tar -czf "$DPISTACK_ROOT/extra.tar.gz" -C "$work" manifest.json files
	run "$CTL" backup verify "$DPISTACK_ROOT/extra.tar.gz"
	[ "$status" -eq 3 ]
	[[ "$output" == *"not in the manifest"* ]]
	rm -rf "$work"
}

@test "verify refuses entries outside files/, absolute paths and links" {
	make_backup
	work="$(mktemp -d)"
	tar -xzf "$ARC" -C "$work"
	printf 'x\n' >"$work/evil"
	tar -czf "$DPISTACK_ROOT/evil.tar.gz" -C "$work" manifest.json files evil
	run "$CTL" backup verify "$DPISTACK_ROOT/evil.tar.gz"
	[ "$status" -eq 3 ]
	[[ "$output" == *"unexpected entry"* ]]
	rm -f "$work/evil"
	ln -s /etc/passwd "$work/files/enable.conf"
	tar -czf "$DPISTACK_ROOT/link.tar.gz" -C "$work" manifest.json files
	run "$CTL" backup verify "$DPISTACK_ROOT/link.tar.gz"
	[ "$status" -eq 3 ]
	[[ "$output" == *"not a plain file"* ]]
	printf 'not an archive\n' >"$DPISTACK_ROOT/junk.tar.gz"
	run "$CTL" backup verify "$DPISTACK_ROOT/junk.tar.gz"
	[ "$status" -eq 3 ]
	rm -rf "$work"
}

@test "verify of a missing archive is code 4" {
	run "$CTL" backup verify nothing.tar.gz
	[ "$status" -eq 4 ]
}

@test "restore gives back the same files and keeps the previous ones" {
	make_backup
	cp "$E/suricata/suricata.yaml" "$DPISTACK_ROOT/yaml.orig"
	printf 'changed: 2\n' >"$E/suricata/suricata.yaml"
	printf 'sid1\nsid2\n' >"$E/suricata/disable.conf"
	run "$CTL" backup restore "$ARC"
	[ "$status" -eq 0 ]
	cmp "$E/suricata/suricata.yaml" "$DPISTACK_ROOT/yaml.orig"
	[ "$(cat "$E/suricata/disable.conf")" = "sid1" ]
	[ "$(stat -c %a "$E/dpistack/users.json")" = "640" ]
	run bash -c "cat '$DPISTACK_ROOT'/var/lib/dpistack/backups/suricata.yaml.*"
	[[ "$output" == *"changed: 2"* ]]
}

@test "restore --dry-run shows the difference and changes nothing" {
	make_backup
	printf 'changed: 2\n' >"$E/suricata/suricata.yaml"
	printf '{"users":[{"name":"other","hash":"secrethash"}]}\n' >"$E/dpistack/users.json"
	run "$CTL" backup restore "$ARC" --dry-run
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed: suricata.yaml"* ]]
	[[ "$output" == *"-changed: 2"* ]]
	[[ "$output" == *"same:    dpistack.conf"* ]]
	[[ "$output" == *"changed: users.json (not shown)"* ]]
	[[ "$output" != *secrethash* ]]
	[ "$(cat "$E/suricata/suricata.yaml")" = "changed: 2" ]
}

@test "restore puts a missing file back as new" {
	make_backup
	rm "$E/suricata/disable.conf"
	run "$CTL" backup restore "$ARC" --dry-run
	[[ "$output" == *"new:     disable.conf"* ]]
	run "$CTL" backup restore "$ARC"
	[ "$status" -eq 0 ]
	[ "$(cat "$E/suricata/disable.conf")" = "sid1" ]
}

@test "restore that fails suricata -T leaves every old file" {
	make_backup
	printf 'live: 1\n' >"$E/suricata/suricata.yaml"
	printf 'sid-live\n' >"$E/suricata/disable.conf"
	MOCK_EXIT=1 run "$CTL" backup restore "$ARC"
	[ "$status" -eq 3 ]
	[[ "$output" == *"suricata -T failed"* ]]
	[ "$(cat "$E/suricata/suricata.yaml")" = "live: 1" ]
	[ "$(cat "$E/suricata/disable.conf")" = "sid-live" ]
}

@test "restore refuses a dpistack.conf that does not pass the schema" {
	make_backup
	work="$(mktemp -d)"
	tar -xzf "$ARC" -C "$work"
	printf 'ACCESS_MODE=nonsense\n' >"$work/files/dpistack.conf"
	sum=$(sha256sum "$work/files/dpistack.conf")
	jq --arg s "${sum%% *}" '(.files[] | select(.name == "dpistack.conf") | .sha256) = $s' "$work/manifest.json" >"$work/m" && mv "$work/m" "$work/manifest.json"
	tar -czf "$DPISTACK_ROOT/badconf.tar.gz" -C "$work" manifest.json files
	run "$CTL" backup restore "$DPISTACK_ROOT/badconf.tar.gz"
	[ "$status" -eq 3 ]
	[ "$(cat "$E/dpistack/dpistack.conf")" = "ACCESS_MODE=localhost" ]
	rm -rf "$work"
}

@test "restore of a damaged archive changes nothing" {
	make_backup
	printf 'changed: 2\n' >"$E/suricata/suricata.yaml"
	work="$(mktemp -d)"
	tar -xzf "$ARC" -C "$work"
	printf 'X' >>"$work/files/enable.conf" 2>/dev/null || printf 'X' >"$work/files/dpistack.conf"
	tar -czf "$DPISTACK_ROOT/dam.tar.gz" -C "$work" manifest.json files
	run "$CTL" backup restore "$DPISTACK_ROOT/dam.tar.gz"
	[ "$status" -eq 3 ]
	[ "$(cat "$E/suricata/suricata.yaml")" = "changed: 2" ]
	rm -rf "$work"
}

@test "a hand-run create and restore are written to the audit log, list and verify are not" {
	make_backup
	"$CTL" backup list >/dev/null
	"$CTL" backup verify "$ARC" >/dev/null
	"$CTL" backup restore "$ARC" --dry-run >/dev/null
	audit="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	[ "$(jq -r 'select(.action == "cli backup") | .target' "$audit" | sort | tr '\n' ' ')" = "create restore " ]
}

@test "unknown backup arguments are code 2" {
	run "$CTL" backup
	[ "$status" -eq 2 ]
	run "$CTL" backup create --bogus
	[ "$status" -eq 2 ]
	run "$CTL" backup restore
	[ "$status" -eq 2 ]
}
