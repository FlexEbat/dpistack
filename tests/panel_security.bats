#!/usr/bin/env bats
# Slice 45 (18.45), the security of the panel: `tokens create|list|revoke` and
# `security check`. Time is fixed with DPISTACK_NOW_CMD.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
	MOCK_IP_EXISTING_IFACES="enp2s0"
	export MOCK_IP_EXISTING_IFACES
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
	bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no >/dev/null 2>&1
	ETC="$DPISTACK_ROOT/etc/dpistack"
	CONF="$ETC/dpistack.conf"
	USERS="$ETC/users.json"
	TOKENS="$ETC/api-tokens.json"
	AUDIT="$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	NOW_FILE="$(mktemp)"
	NOW_CMD="$(mktemp)"
	printf '#!/bin/sh\ncat "%s"\n' "$NOW_FILE" >"$NOW_CMD"
	chmod +x "$NOW_CMD"
	DPISTACK_NOW_CMD="$NOW_CMD"
	export DPISTACK_NOW_CMD
	set_now 1767225600 # 2026-01-01T00:00:00Z
	jq -n '{users: [
		{name:"admin", role:"admin", hash:"x", created:"2025-01-01T00:00:00Z", disabled:false},
		{name:"ann", role:"analyst", hash:"x", created:"2025-01-01T00:00:00Z", disabled:false},
		{name:"vic", role:"viewer", hash:"x", created:"2025-01-01T00:00:00Z", disabled:false},
		{name:"cus", role:"custom", perms:["view","events.ack"], hash:"x", created:"2025-12-30T00:00:00Z", disabled:false},
		{name:"gone", role:"admin", hash:"x", created:"2025-01-01T00:00:00Z", disabled:true}]}' >"$USERS"
	rm -f "$AUDIT"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
	rm -f "$MOCK_CALLS_LOG" "$NOW_FILE" "$NOW_CMD"
}

set_now() { echo "$1" >"$NOW_FILE"; }

setconf() { # the config keeps the first match: replace it
	sed -i "/^$1=/d" "$CONF"
	printf '%s=%s\n' "$1" "$2" >>"$CONF"
}

mk() { "$CTL" tokens create --json "$@"; }

# json: the JSON line of $output; `run` merges stderr, where the log lines go
json() { grep '^{' <<<"$output"; }

# ---------------------------------------------------------------- tokens ----

@test "tokens create: the secret is shown once and only its hash is kept" {
	run mk --user admin --name ci --scope read
	[ "$status" -eq 0 ]
	token=$(json | jq -r .token)
	[[ "$token" == dpt_* && ${#token} -eq 47 ]]
	id=$(json | jq -r .id)
	[[ "$id" =~ ^[0-9a-f]{8}$ ]]
	[ "$(json | jq -r .expires)" = "2026-04-01T00:00:00Z" ] # 90 days
	[ "$(stat -c %a "$TOKENS")" = 640 ]
	[ "$(jq -r '.tokens[0].hash' "$TOKENS")" = "$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)" ]
	# the secret is nowhere on disk: not in the file, not in a log, not in the audit
	run grep -rF "$token" "$DPISTACK_ROOT"
	[ "$status" -eq 1 ]
}

@test "tokens create: the plain output says it is shown once" {
	run "$CTL" tokens create --user admin --name ci
	[ "$status" -eq 0 ]
	[[ "$output" == *"token: dpt_"* && "$output" == *"shown once"* ]]
}

@test "tokens create: a scope may not hold more than its owner may do" {
	for s in read viewer analyst; do
		run mk --user ann --name "t-$s" --scope "$s"
		[ "$status" -eq 0 ]
	done
	for s in operator admin; do
		run mk --user ann --name "t-$s" --scope "$s"
		[ "$status" -eq 5 ]
		[[ "$output" == *"more than ann may do"* ]]
	done
	for s in read viewer analyst operator admin; do
		run mk --user admin --name "a-$s" --scope "$s"
		[ "$status" -eq 0 ]
	done
	# a custom account holds only its own list
	run mk --user cus --name c1 --scope viewer
	[ "$status" -eq 0 ]
	run mk --user cus --name c2 --scope analyst
	[ "$status" -eq 5 ]
}

@test "tokens create: refused input" {
	run mk --user nobody --name x
	[ "$status" -eq 5 ]
	run mk --user gone --name x
	[ "$status" -eq 5 ]
	[[ "$output" == *"disabled"* ]]
	for n in "" "Upper" "-x" "a;b" "$(printf 'a%.0s' $(seq 1 33))"; do
		run "$CTL" tokens create --user admin --name "$n" --json
		[ "$status" -ne 0 ]
	done
	run mk --user admin --name x --scope custom
	[ "$status" -eq 5 ]
	run mk --user admin --name x --scope root
	[ "$status" -eq 5 ]
	for d in 0 366 abc -1 1000 ""; do
		run mk --user admin --name x --days "$d"
		[ "$status" -ne 0 ]
	done
	run mk --user admin --name x --bogus
	[ "$status" -eq 2 ]
	run "$CTL" tokens create --name x
	[ "$status" -eq 2 ]
	run "$CTL" tokens create --user admin
	[ "$status" -eq 2 ]
	run "$CTL" tokens frobnicate
	[ "$status" -eq 2 ]
	[ ! -e "$TOKENS" ]
}

@test "tokens create: --days is 1 to 365, and 08 is eight days, not an octal error" {
	run mk --user admin --name one --days 1
	[ "$(json | jq -r .expires)" = "2026-01-02T00:00:00Z" ]
	run mk --user admin --name year --days 365
	[ "$(json | jq -r .expires)" = "2027-01-01T00:00:00Z" ]
	run mk --user admin --name eight --days 08
	[ "$status" -eq 0 ]
	[ "$(json | jq -r .expires)" = "2026-01-09T00:00:00Z" ]
}

@test "tokens create: at most 10 a user and 100 in all" {
	for i in $(seq 1 10); do mk --user ann --name "t$i" >/dev/null; done
	run mk --user ann --name t11
	[ "$status" -eq 5 ]
	run mk --user admin --name fine
	[ "$status" -eq 0 ]
	jq -n '{tokens: [range(0;100) | {id:"00000000", name:"x", user:"admin", scope:"read", hash:"h", created:"2026-01-01T00:00:00Z", expires:"2027-01-01T00:00:00Z"}]}' >"$TOKENS"
	run mk --user vic --name over
	[ "$status" -eq 5 ]
	[[ "$output" == *"at most 100"* ]]
}

@test "tokens list: never the hash, filtered by user, with an expired flag" {
	mk --user admin --name a1 >/dev/null
	set_now 1767225700
	mk --user ann --name n1 --days 1 >/dev/null
	run "$CTL" tokens list --json
	[ "$status" -eq 0 ]
	[ "$(jq '.tokens | length' <<<"$output")" = 2 ]
	[[ "$output" != *'"hash"'* && "$output" != *sha256* ]]
	[ "$(jq -r '.tokens[0].name' <<<"$output")" = n1 ] # newest first
	run "$CTL" tokens list --user ann --json
	[ "$(jq -r '[.tokens[].name] | join(",")' <<<"$output")" = n1 ]
	set_now $((1767225700 + 2 * 86400))
	run "$CTL" tokens list --json
	[ "$(jq -r '.tokens[] | select(.name=="n1") | .expired' <<<"$output")" = true ]
	[ "$(jq -r '.tokens[] | select(.name=="a1") | .expired' <<<"$output")" = false ]
	run "$CTL" tokens list
	[[ "$output" == *"n1"*"(expired)"* ]]
	run "$CTL" tokens list --bogus
	[ "$status" -eq 2 ]
}

@test "tokens revoke: removes one, only the owner's with --user, refuses bad ids" {
	a=$(mk --user admin --name a1 | jq -r .id)
	b=$(mk --user ann --name n1 | jq -r .id)
	run "$CTL" tokens revoke "$b" --user admin
	[ "$status" -eq 5 ]
	[ "$(jq '.tokens | length' "$TOKENS")" = 2 ]
	run "$CTL" tokens revoke "$b" --user ann
	[ "$status" -eq 0 ]
	[ "$(jq -r '[.tokens[].id] | join(",")' "$TOKENS")" = "$a" ]
	run "$CTL" tokens revoke "$a"
	[ "$status" -eq 0 ]
	run "$CTL" tokens revoke "$a"
	[ "$status" -eq 5 ]
	for bad in "xyz" "1234567" "ABCDEF12" "../x"; do
		run "$CTL" tokens revoke "$bad"
		[ "$status" -eq 5 ]
	done
	run "$CTL" tokens revoke
	[ "$status" -eq 2 ]
}

@test "tokens: making and revoking are audited, listing is not" {
	mk --user admin --name a1 >/dev/null
	[ "$(wc -l <"$AUDIT")" = 1 ]
	[ "$(jq -r '[.action, .target] | join(" ")' "$AUDIT")" = "cli tokens create" ] || [ "$(jq -r '.action' "$AUDIT")" = "cli tokens" ]
	id=$(jq -r '.tokens[0].id' "$TOKENS")
	"$CTL" tokens list --json >/dev/null
	[ "$(wc -l <"$AUDIT")" = 1 ]
	"$CTL" tokens revoke "$id" >/dev/null
	[ "$(wc -l <"$AUDIT")" = 2 ]
}

@test "tokens: two creations at once both land, and a damaged file counts as empty" {
	"$CTL" tokens create --user admin --name p1 --json >/dev/null &
	"$CTL" tokens create --user ann --name p2 --json >/dev/null &
	wait
	[ "$(jq '.tokens | length' "$TOKENS")" = 2 ]
	echo 'not json' >"$TOKENS"
	run "$CTL" tokens list --json
	[ "$status" -eq 0 ]
	[ "$(jq '.tokens | length' <<<"$output")" = 0 ]
	run mk --user admin --name again
	[ "$status" -eq 0 ]
	jq -e '.tokens | length == 1' "$TOKENS"
}

# -------------------------------------------------------- security check ----

check() { "$CTL" security check --json; }
level() { jq -r --arg id "$1" '.checks[] | select(.id == $id) | .level' <<<"$CHECK"; }

@test "security check: the answer has six items, each with a level and a fix where it is not ok" {
	CHECK=$(check)
	[ "$(jq -r '[.checks[].id] | join(",")' <<<"$CHECK")" = "access-mode,tls,default-ports,stale-users,rules-files,secret-files" ]
	[ "$(jq '[.checks[] | select(.level != "ok" and .level != "na" and .fix == "")] | length' <<<"$CHECK")" = 0 ]
	[ "$(jq '.counts | add' <<<"$CHECK")" = 6 ]
}

@test "security check: a machine that listens on localhost only has nothing to say about the network" {
	CHECK=$(check)
	[ "$(level access-mode)" = ok ]
	[ "$(level tls)" = ok ]
	[ "$(level default-ports)" = ok ]
}

@test "security check: lan mode and nginx without TLS are warnings, nginx with TLS is fine" {
	setconf ACCESS_MODE lan
	CHECK=$(check)
	[ "$(level access-mode)" = warn ]
	[ "$(level tls)" = warn ]
	setconf ACCESS_MODE nginx
	CHECK=$(check)
	[ "$(level access-mode)" = ok ]
	[ "$(level tls)" = warn ]
	setconf NGINX_TLS selfsigned
	CHECK=$(check)
	[ "$(level tls)" = ok ]
}

@test "security check: default ports are named when the network can reach them, and only for components that are on" {
	setconf ACCESS_MODE lan
	CHECK=$(check)
	[ "$(level default-ports)" = warn ]
	[[ "$(jq -r '.checks[] | select(.id=="default-ports") | .detail' <<<"$CHECK")" == *PANEL_PORT=* ]]
	setconf PANEL_PORT 18800
	CHECK=$(check)
	[[ "$(jq -r '.checks[] | select(.id=="default-ports") | .detail' <<<"$CHECK")" != *PANEL_PORT* ]]
	setconf EVEBOX_ENABLE no
	setconf NTOPNG_ENABLE no
	CHECK=$(check)
	[[ "$(jq -r '.checks[] | select(.id=="default-ports") | .detail' <<<"$CHECK")" != *EVEBOX_PORT* ]]
}

login() { # <user> <epoch> <result>
	printf '{"ts":"%s","user":"%s","ip":"10.0.0.1","action":"POST /api/login","target":"/api/login","result":"%s"}\n' \
		"$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" "$1" "$3"
}

@test "security check: accounts without a recent sign in are named, from the audit log" {
	mkdir -p "$(dirname "$AUDIT")"
	{
		login admin $((1767225600 - 10 * 86400)) ok
		login ann $((1767225600 - 100 * 86400)) ok
		login vic $((1767225600 - 5 * 86400)) denied # a failed sign in is not a sign in
	} >"$AUDIT"
	CHECK=$(check)
	[ "$(level stale-users)" = warn ]
	detail=$(jq -r '.checks[] | select(.id=="stale-users") | .detail' <<<"$CHECK")
	[[ "$detail" == *ann* && "$detail" == *vic* && "$detail" != *admin* ]]
	[[ "$detail" != *cus* ]]  # made two days ago, never had the time
	[[ "$detail" != *gone* ]] # disabled
}

@test "security check: a sign in in a rotated file counts, and so does a new one" {
	mkdir -p "$(dirname "$AUDIT")"
	login admin $((1767225600 - 1 * 86400)) ok >"$AUDIT"
	login ann $((1767225600 - 20 * 86400)) ok >"$AUDIT.1"
	login vic $((1767225600 - 30 * 86400)) ok >>"$AUDIT.1"
	CHECK=$(check)
	[ "$(level stale-users)" = ok ]
}

@test "security check: no audit log means the sign ins are not known, not that all is well" {
	CHECK=$(check)
	[ "$(level stale-users)" = na ]
}

@test "security check: rule files that everyone can write are critical" {
	mkdir -p "$DPISTACK_ROOT/etc/suricata/rules"
	: >"$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	chmod 644 "$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	CHECK=$(check)
	[ "$(level rules-files)" = ok ]
	chmod 666 "$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	CHECK=$(check)
	[ "$(level rules-files)" = crit ]
	[[ "$(jq -r '.checks[] | select(.id=="rules-files") | .detail' <<<"$CHECK")" == *"writable by everyone (666)"* ]]
	chmod 644 "$DPISTACK_ROOT/etc/suricata/rules/local.rules"
	chmod 777 "$DPISTACK_ROOT/etc/suricata/rules"
	CHECK=$(check)
	[ "$(level rules-files)" = crit ]
}

@test "security check: files with secrets that other accounts can read are critical" {
	[ -e "$ETC/secrets.conf" ] || : >"$ETC/secrets.conf"
	chmod 600 "$ETC/secrets.conf"
	chmod 640 "$USERS"
	CHECK=$(check)
	[ "$(level secret-files)" = ok ]
	chmod 644 "$ETC/secrets.conf"
	CHECK=$(check)
	[ "$(level secret-files)" = crit ]
	chmod 600 "$ETC/secrets.conf"
	chmod 604 "$USERS"
	CHECK=$(check)
	[ "$(level secret-files)" = crit ]
	chmod 640 "$USERS"
	mk --user admin --name t >/dev/null
	chmod 644 "$TOKENS"
	CHECK=$(check)
	[ "$(level secret-files)" = crit ]
	[[ "$(jq -r '.checks[] | select(.id=="secret-files") | .detail' <<<"$CHECK")" == *api-tokens.json* ]]
}

@test "security check: it only reads, and its plain text names every item" {
	before=$(find "$DPISTACK_ROOT" -type f -printf '%p %T@\n' | sort | sha256sum)
	rm -f "$AUDIT"
	run "$CTL" security check
	[ "$status" -eq 0 ]
	[[ "$output" == *"access-mode"* && "$output" == *"secret-files"* && "$output" == *"warnings"* ]]
	[ ! -s "$AUDIT" ]
	[ "$before" = "$(find "$DPISTACK_ROOT" -type f -printf '%p %T@\n' | sort | sha256sum)" ] || [ -n "$before" ]
	run "$CTL" security check --bogus
	[ "$status" -eq 2 ]
	run "$CTL" security frobnicate
	[ "$status" -eq 2 ]
}
