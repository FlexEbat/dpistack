#!/usr/bin/env bats
# Slice 34: users, roles and permissions: the verb `dpistack users ...`.
# The table of the roles is compared with panel/internal/auth/testdata/presets.json,
# which the Go tests compare with the table of the panel.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	USERS="$DPISTACK_ROOT/etc/dpistack/users.json"
	PW="correct horse battery"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

seed_admin() {
	"$CTL" panel-passwd <<<"$PW" >/dev/null
}

@test "panel-passwd makes the user admin and keeps panel.auth the same hash" {
	run "$CTL" panel-passwd <<<"$PW"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.users[0].name' "$USERS")" = "admin" ]
	[ "$(jq -r '.users[0].role' "$USERS")" = "admin" ]
	[ "$(jq -r '.users[0].hash' "$USERS")" = "$(head -n 1 "$DPISTACK_ROOT/etc/dpistack/panel.auth")" ]
	[ "$(stat -c %a "$USERS")" = "640" ]
}

@test "an old panel.auth becomes the user admin with the same hash on the first users call" {
	hash=$(printf '%s' "$PW" | argon2 saltsaltsalt -id -t 3 -m 14 -p 4 -l 32 -e)
	printf '%s\n' "$hash" >"$DPISTACK_ROOT/etc/dpistack/panel.auth"
	run "$CTL" users list --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.users[0].name')" = "admin" ]
	[ "$(jq -r '.users[0].hash' "$USERS")" = "$hash" ]
}

@test "the permissions of every role equal the golden table" {
	seed_admin
	golden="$REPO_DIR/panel/internal/auth/testdata/presets.json"
	for role in viewer analyst operator admin; do
		"$CTL" users add "u-$role" "$role" <<<"$PW" >/dev/null
	done
	run "$CTL" users list --json
	for role in viewer analyst operator admin; do
		got=$(echo "$output" | jq -c --arg n "u-$role" '.users[] | select(.name==$n) | .perms | sort')
		want=$(jq -c --arg r "$role" '.roles[$r] | sort' "$golden")
		[ "$got" = "$want" ]
	done
	[ "$(jq -c '.perms | sort' "$golden")" = "$(jq -c '.roles.admin | sort' "$golden")" ]
}

@test "a custom role carries its own permissions and refuses unknown ones" {
	seed_admin
	run "$CTL" users add bob custom --perms view,rules.edit <<<"$PW"
	[ "$status" -eq 0 ]
	run "$CTL" users list --json
	[ "$(echo "$output" | jq -c '.users[] | select(.name=="bob") | .perms')" = '["rules.edit","view"]' ]
	run "$CTL" users add eve custom --perms view,fly <<<"$PW"
	[ "$status" -eq 2 ]
	run "$CTL" users add eve custom <<<"$PW"
	[ "$status" -eq 2 ]
	run "$CTL" users add eve viewer --perms view <<<"$PW"
	[ "$status" -eq 2 ]
}

@test "names, roles and short passwords are refused and nothing is written" {
	seed_admin
	before=$(sha256sum "$USERS")
	run "$CTL" users add "Bad Name" viewer <<<"$PW"
	[ "$status" -eq 5 ] || [ "$status" -eq 2 ]
	run "$CTL" users add bob boss <<<"$PW"
	[ "$status" -eq 2 ]
	run "$CTL" users add bob viewer <<<"short"
	[ "$status" -eq 2 ]
	run "$CTL" users add admin viewer <<<"$PW"
	[ "$status" -eq 3 ]
	[ "$before" = "$(sha256sum "$USERS")" ]
}

@test "the password is never stored or listed, only its hash" {
	seed_admin
	"$CTL" users add bob viewer <<<"hunter2hunter2" >/dev/null
	run grep -c 'hunter2hunter2' "$USERS"
	[ "$output" = "0" ]
	run "$CTL" users list --json
	[ "$(echo "$output" | grep -c 'argon2id')" = "0" ]
	[ "$(jq -r '.users[] | select(.name=="bob") | .hash' "$USERS" | cut -c1-10)" = '$argon2id$' ]
}

@test "the last user who may manage users cannot be removed, disabled or demoted" {
	seed_admin
	run "$CTL" users remove admin
	[ "$status" -eq 3 ]
	run "$CTL" users disable admin
	[ "$status" -eq 3 ]
	run "$CTL" users role admin viewer
	[ "$status" -eq 3 ]
	"$CTL" users add second admin <<<"$PW" >/dev/null
	run "$CTL" users role admin viewer
	[ "$status" -eq 0 ]
	run "$CTL" users disable second
	[ "$status" -eq 3 ]
}

@test "passwd changes the hash of that user only and admin keeps panel.auth in step" {
	seed_admin
	"$CTL" users add bob viewer <<<"$PW" >/dev/null
	admin_before=$(jq -r '.users[] | select(.name=="admin") | .hash' "$USERS")
	bob_before=$(jq -r '.users[] | select(.name=="bob") | .hash' "$USERS")
	run "$CTL" users passwd bob <<<"another long one"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.users[] | select(.name=="bob") | .hash' "$USERS")" != "$bob_before" ]
	[ "$(jq -r '.users[] | select(.name=="admin") | .hash' "$USERS")" = "$admin_before" ]
	"$CTL" users passwd admin <<<"admin changed pw" >/dev/null
	[ "$(jq -r '.users[] | select(.name=="admin") | .hash' "$USERS")" = "$(head -n 1 "$DPISTACK_ROOT/etc/dpistack/panel.auth")" ]
	run "$CTL" users passwd nobody <<<"$PW"
	[ "$status" -eq 4 ]
}

@test "disable, enable and remove work on a second user" {
	seed_admin
	"$CTL" users add bob operator <<<"$PW" >/dev/null
	"$CTL" users disable bob >/dev/null
	[ "$("$CTL" users list --json | jq -r '.users[] | select(.name=="bob") | .disabled')" = "true" ]
	"$CTL" users enable bob >/dev/null
	[ "$("$CTL" users list --json | jq -r '.users[] | select(.name=="bob") | .disabled')" = "false" ]
	"$CTL" users remove bob >/dev/null
	[ "$("$CTL" users list --json | jq -r '[.users[] | select(.name=="bob")] | length')" = "0" ]
}

@test "an unknown subcommand gives 2 and the verb is open to the panel" {
	run "$CTL" users frobnicate
	[ "$status" -eq 2 ]
	grep -q 'runtime users version' "$REPO_DIR/install.sh"
}
