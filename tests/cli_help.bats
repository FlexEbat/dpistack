#!/usr/bin/env bats
# Step 3 of the menu review (18.54): grouped help, <command> --help, the
# two-word spelling of a command, "did you mean" and Tab completion.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export MOCK_IP_EXISTING_IFACES="enp2s0"
	export DPISTACK_MENU_ASSUME_YES=1
	MOCK_CALLS_LOG="$(mktemp)"
	export MOCK_CALLS_LOG
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$MOCK_CALLS_LOG"
}

@test "help groups the commands by what a person wants to do and ends with the exit codes" {
	run "$CTL" help
	[ "$status" -eq 0 ]
	for g in "Look at it" "Control it" "Rules and alerts" "Settings and files" "People and access" "Keep it safe"; do
		[[ "$output" == *"$g"* ]]
	done
	[[ "$output" == *"Exit codes: 0 ok, 1 error, 2 misuse"* ]]
	[[ "$output" == *"Under development: dpistack is still being developed."* ]]
}

@test "help --all is the flat reference, the same text a bad command prints" {
	run "$CTL" help --all
	[ "$status" -eq 0 ]
	[[ "$output" == *"exceptions list"* ]]
	[[ "$output" == *"rules-find"* ]]
	run "$CTL" nonsense
	[ "$status" -eq 2 ]
	[[ "$output" == *"exceptions list"* ]]
}

@test "help settings says which of the three ways to use" {
	run "$CTL" help settings
	[ "$status" -eq 0 ]
	[[ "$output" == *"settings set K=V"* ]]
	[[ "$output" == *"reconfigure"* ]]
	[[ "$output" == *"config write <name> --apply"* ]]
}

@test "help ids lists the components and the config names" {
	run "$CTL" help ids
	[ "$status" -eq 0 ]
	[[ "$output" == *"Components: suricata evebox ntopng"* ]]
	[[ "$output" == *"threshold.config"* ]]
}

@test "<command> --help prints that command's lines and runs nothing" {
	run "$CTL" rules-find --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"rules-find [--class C]"* ]]
	[[ "$output" != *"rules-update "* ]]
	[[ "$output" == *"Exit codes:"* ]]
	run "$CTL" backup -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"backup create"* ]]
}

@test "the two-word spelling is the one-word command: --help of rules update, config read, mode confirm" {
	run "$CTL" rules update --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"rules-update "* ]]
	run "$CTL" config read --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"config-read <name>"* ]]
	run "$CTL" mode confirm --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"mode-confirm "* ]]
	run "$CTL" rules --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"rules-sources"* && "$output" == *"rules-find"* ]]
}

@test "config read and config-read give the same file, the old spelling still works" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'SURICATA_MODE=ids\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" config-read dpistack.conf
	[ "$status" -eq 0 ]
	old="$output"
	run "$CTL" config read dpistack.conf
	[ "$status" -eq 0 ]
	[ "$output" = "$old" ]
	[[ "$output" == *"SURICATA_MODE=ids"* ]]
}

@test "a two-word spelling is audited as the verb it stands for" {
	run "$CTL" rules sid enable 2001
	run jq -r '.action + " " + .target' "$DPISTACK_ROOT/var/lib/dpistack/audit/audit.jsonl"
	[[ "$output" == *"cli rules-sid enable"* ]]
}

@test "an unknown command gets a did-you-mean line before the usage" {
	run "$CTL" sett
	[ "$status" -eq 2 ]
	[[ "${lines[0]}" == *"Did you mean: settings"* ]]
	run "$CTL" rulesupdate
	[ "$status" -eq 2 ]
	[[ "${lines[0]}" == *"rules-update"* ]]
}

@test "dpistack --help names the command it was started as" {
	mkdir -p "$DPISTACK_ROOT/bin"
	ln -s "$REPO_DIR/install.sh" "$DPISTACK_ROOT/bin/dpistack"
	run "$DPISTACK_ROOT/bin/dpistack" --help
	[[ "$output" == *"Usage: dpistack [command] [options]"* ]]
	[[ "$output" != *"install.sh"* ]]
	run bash "$REPO_DIR/install.sh" --help
	[[ "$output" == *"Usage: install.sh [command] [options]"* ]]
}

@test "the completion file lists exactly the commands of the CLI and the installer" {
	local words known
	words=$(sed -n 's/^\tlocal verbs="\(.*\)"$/\1/p' "$REPO_DIR/templates/dpistack.completion.bash" | tr ' ' '\n' | sort)
	known=$(
		bash -c '
			source "$1/lib/ctl.sh" 2>/dev/null
			printf "%s\n" "${CTL_ALL_VERBS[@]}" install upgrade uninstall diag
		' _ "$REPO_DIR" | sort -u
	)
	# mode-rollback is internal (the timer calls it): it is not completed.
	[ "$words" = "$(printf '%s\n' "$known" | grep -vx 'mode-rollback')" ]
}

@test "completion proposes verbs, components and config names" {
	run bash -c '
		source "$1/templates/dpistack.completion.bash"
		COMP_WORDS=(dpistack rest); COMP_CWORD=1; _dpistack; printf "%s\n" "${COMPREPLY[@]}"
		COMP_WORDS=(dpistack restart sur); COMP_CWORD=2; _dpistack; printf "%s\n" "${COMPREPLY[@]}"
		COMP_WORDS=(dpistack config read thr); COMP_CWORD=3; _dpistack; printf "%s\n" "${COMPREPLY[@]}"
		COMP_WORDS=(dpistack rules fi); COMP_CWORD=2; _dpistack; printf "%s\n" "${COMPREPLY[@]}"
	' _ "$REPO_DIR"
	[ "$status" -eq 0 ]
	[[ "$output" == *"restart"* && "$output" == *"suricata"* && "$output" == *"threshold.config"* && "$output" == *"find"* ]]
}

@test "the install puts the completion file in place and uninstall takes it away" {
	run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[ "$status" -eq 0 ]
	[ -f "$DPISTACK_ROOT/etc/bash_completion.d/dpistack" ]
	cmp "$DPISTACK_ROOT/etc/bash_completion.d/dpistack" "$REPO_DIR/templates/dpistack.completion.bash"
	local in
	in="$(mktemp)"
	printf 'remove\n' >"$in"
	DPISTACK_INPUT="$in" run bash "$REPO_DIR/install.sh" uninstall
	rm -f "$in"
	[ "$status" -eq 0 ]
	[ ! -e "$DPISTACK_ROOT/etc/bash_completion.d/dpistack" ]
}

@test "info prints the address of every switched-on screen for the access mode" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'ACCESS_MODE=lan\nBIND_ADDR=192.168.1.5\nEVEBOX_ENABLE=no\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" info
	[ "$status" -eq 0 ]
	[[ "$output" == *"panel    http://192.168.1.5:9800"* ]]
	[[ "$output" == *"ntopng   http://192.168.1.5:3000"* ]]
	[[ "$output" != *"evebox"* ]]
	run "$CTL" info --json
	[ "$(jq -r '.screens | map(.id) | join(",")' <<<"$output")" = "panel,ntopng" ]
	printf 'ACCESS_MODE=nginx\nBIND_ADDR=10.0.0.9\nNGINX_TLS=selfsigned\nNTOPNG_ENABLE=no\nEVEBOX_ENABLE=no\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" info
	[[ "$output" == *"https://10.0.0.9:9800"* ]]
}

@test "info in localhost mode says it is this machine only and how to reach it" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'ACCESS_MODE=localhost\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	run "$CTL" info
	[ "$status" -eq 0 ]
	[[ "$output" == *"http://127.0.0.1:9800"* && "$output" == *"this machine only"* && "$output" == *"ssh -L"* ]]
	run "$CTL" info extra
	[ "$status" -eq 2 ]
}
