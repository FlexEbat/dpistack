#!/usr/bin/env bats
# v0.29.1: `dpistack diagnose`: a part that does not run is reported with its
# state, the exit status and the last lines of its log.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	CTL="$REPO_DIR/tests/helpers/verbs"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	FAKE_BIN="$(mktemp -d)"
	cat >"$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
show)
	if [[ "$*" == *Result* ]]; then printf 'Result=exit-code\nExecMainStatus=1\n'; else echo loaded; fi
	;;
is-active)
	case "$*" in
	*suricata.service*) echo failed; exit 3 ;;
	*) echo active ;;
	esac
	;;
is-enabled) exit 0 ;;
esac
FAKE
	cat >"$FAKE_BIN/journalctl" <<'FAKE'
#!/usr/bin/env bash
echo "journalctl $*"
echo "suricata[1]: Error: the plugin could not be loaded"
FAKE
	printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN/dpkg-query"
	chmod +x "$FAKE_BIN"/*
	PATH="$FAKE_BIN:$PATH"
	export PATH
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$FAKE_BIN"
}

@test "a failed part is named with its exit status and the last lines of its log" {
	run "$CTL" diagnose
	[ "$status" -eq 0 ]
	[[ "$output" == *"suricata: suricata.service is failed"* ]]
	[[ "$output" == *"ExecMainStatus=1"* ]]
	[[ "$output" == *"journalctl -u suricata.service -n 25"* ]]
	[[ "$output" == *"the plugin could not be loaded"* ]]
}

@test "a part that runs is not reported" {
	run "$CTL" diagnose evebox
	[ "$status" -eq 0 ]
	[[ "$output" == *"every selected part is running"* ]]
	[[ "$output" != *"journalctl"* ]]
}

@test "an unknown part gives 2" {
	run "$CTL" diagnose frobnicate
	[ "$status" -eq 2 ]
}
