#!/usr/bin/env bats
# lib/render.sh: @@KEY@@ inline and block substitution.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	TPL="$(mktemp)"
}

teardown() {
	rm -f "$TPL"
}

render() {
	bash -c 'source "'"$REPO_DIR"'/lib/render.sh"; render_template "$@"' _ "$TPL" "$@"
}

@test "inline placeholders are replaced, several per line" {
	printf 'a=@@A@@ b=@@B@@ a-again=@@A@@\n' >"$TPL"
	run render A=1 B=two
	[ "$status" -eq 0 ]
	[ "$output" = "a=1 b=two a-again=1" ]
}

@test "a whole-line placeholder expands to a multi-line block" {
	printf 'top\n@@BLOCK@@\nbottom\n' >"$TPL"
	run render "BLOCK=x: 1
y: 2"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "top" ]
	[ "${lines[1]}" = "x: 1" ]
	[ "${lines[2]}" = "y: 2" ]
	[ "${lines[3]}" = "bottom" ]
}

@test "an empty block drops its line" {
	printf 'top\n@@BLOCK@@\nbottom\n' >"$TPL"
	run render BLOCK=
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 2 ]
}

@test "values are literal: ampersands and backslashes survive" {
	printf 'url=@@U@@\n' >"$TPL"
	run render 'U=http://h/?a=1&b=2\n\\x'
	[ "$status" -eq 0 ]
	[ "$output" = 'url=http://h/?a=1&b=2\n\\x' ]
}

@test "a placeholder with no value fails loudly instead of leaking into the output" {
	printf 'x=@@MISSING@@\n' >"$TPL"
	run render A=1
	[ "$status" -ne 0 ]
	[[ "$output" == *"@@MISSING@@"* ]]
}

@test "a block placeholder with no value fails loudly" {
	printf '@@MISSING_BLOCK@@\n' >"$TPL"
	run render A=1
	[ "$status" -ne 0 ]
}

@test "a missing template is an error" {
	rm -f "$TPL"
	run render A=1
	[ "$status" -ne 0 ]
}

@test "leading whitespace and dollar signs in the template are preserved" {
	printf '    proxy_set_header Host $host;\n' >"$TPL"
	run render A=1
	[ "$output" = '    proxy_set_header Host $host;' ]
}
