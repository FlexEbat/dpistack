#!/usr/bin/env bats
# Covers slice 1 criterion 8: a second concurrent install.sh instance
# must exit 1 because the first instance holds the flock.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	mkdir -p "$DPISTACK_ROOT/etc" "$DPISTACK_ROOT/var/lock"
	cat >"$DPISTACK_ROOT/etc/os-release" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
	PATH="$REPO_DIR/tests/mocks:$PATH"
	export PATH
}

teardown() {
	kill "$holder_pid" 2>/dev/null || true
	wait "$holder_pid" 2>/dev/null || true
	rm -rf "$DPISTACK_ROOT"
}

@test "second instance exits 1 while the lock is held" {
	lock_file="$DPISTACK_ROOT/var/lock/dpistack.lock"
	(
		exec 200>"$lock_file"
		flock 200
		sleep 5
	) &
	holder_pid=$!

	for _ in 1 2 3 4 5 6 7 8 9 10; do
		flock -n -w 0 "$lock_file" -c true 2>/dev/null && sleep 0.1 || break
	done

	run bash "$REPO_DIR/install.sh" install --dry-run -y
	[ "$status" -eq 1 ]
	[[ "$output" == *"another dpistack instance is running"* ]]
}
