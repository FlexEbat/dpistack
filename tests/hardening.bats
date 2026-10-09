#!/usr/bin/env bats
# shellcheck disable=SC2016 # single quotes are meant: literal hostile values and code for `lib`
# Regression tests for defects found in the full code review (tech.md 18).
# Each test fails on the code as it was before the fix.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	CTL="$REPO_DIR/bin/dpistack-ctl"
	# The libraries define their own `run`, which would shadow bats' run,
	# so every check that needs them goes through `lib`.
	PRE="source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/state.sh'; source '$REPO_DIR/lib/schema.sh'; source '$REPO_DIR/lib/os.sh'"
}

# lib <bash code> - runs the code with the installer libraries loaded
lib() {
	bash -c "$PRE; $1"
}

teardown() {
	rm -rf "$DPISTACK_ROOT"
}

@test "run returns the real exit code of a failing command" {
	run lib 'run false 2>/dev/null; exit $?'
	[ "$status" -eq 1 ]
	run lib "run bash -c 'exit 7' 2>/dev/null; exit \$?"
	[ "$status" -eq 7 ]
	run lib 'run true 2>/dev/null; exit $?'
	[ "$status" -eq 0 ]
}

@test "run in a || chain takes the failure branch" {
	run lib 'run false 2>/dev/null || echo failed-branch'
	[[ "$output" == *"failed-branch"* ]]
}

@test "atomic_write keeps the old file when the write fails" {
	target="$DPISTACK_ROOT/etc/app.conf"
	mkdir -p "$(dirname "$target")"
	echo "good" >"$target"
	shim="$(mktemp -d)"
	printf '#!/bin/sh\nexit 1\n' >"$shim/cat"
	chmod +x "$shim/cat"
	PATH="$shim:$PATH" run lib "echo new | atomic_write '$target'"
	rm -rf "$shim"
	[ "$status" -ne 0 ]
	[ "$(cat "$target")" = "good" ]
	[ -z "$(find "$(dirname "$target")" -name '.tmp.*')" ]
}

@test "state keys are compared as text, not as regular expressions" {
	run lib 'state_write_value watch.miss.a 1; state_write_value watchXmissXa 2; state_write_value watch.miss.a 3
		echo "[$(state_read_value watch.miss.a)][$(state_read_value watchXmissXa)][$(state_read_value watch)]"'
	[ "$output" = "[3][2][]" ]
}

@test "two writers of the state file lose no key" {
	lib 'writer() { local p="$1" i; for i in $(seq 1 15); do state_write_value "${p}.k$i" "$i"; done; }
		writer a & writer b & wait'
	[ "$(grep -c '^a\.k' "$DPISTACK_ROOT/var/lib/dpistack/state")" -eq 15 ]
	[ "$(grep -c '^b\.k' "$DPISTACK_ROOT/var/lib/dpistack/state")" -eq 15 ]
}

@test "free-text keys reject values that would break a config or a command" {
	bad=(
		'LAN_CIDR=10.0.0.0/8; } server { listen 1;'
		'LAN_CIDR=10.0.0.0'
		'TEST_HTTPS_URL=-o/etc/cron.d/x'
		'TEST_HTTPS_URL=https://a.example/"x'
		'TEST_HTTPS_URL=file:///etc/shadow'
		"EVEBOX_ES_URL=https://x/\$(id)"
		'IFACES=eth0 eth1'
		'IFACES=-eth0'
		'IFACES=eth0;id'
		'BPF_FILTER=a"; touch /x'
		'BPF_FILTER=a`id`'
		'HOME_NET=10.0.0.0/8,evil;'
		'NGINX_CERT=/etc/x;include /etc/shadow'
		'NGINX_CERT=relative/path'
		'RULES_SOURCES=-D /etc'
		'RULES_URLS=ftp://x/y'
		'ALERT_MAIL_TO=a@b.c;rm'
		'EVE_TYPES=alert,flow;x'
	)
	for kv in "${bad[@]}"; do
		KV="${kv#*=}" run bash -c "$PRE; schema_validate_one '${kv%%=*}' \"\$KV\""
		[ "$status" -eq 1 ] || {
			echo "accepted: $kv"
			return 1
		}
	done
}

@test "ordinary free-text values are still accepted" {
	good=(
		'LAN_CIDR=auto'
		'LAN_CIDR=192.168.1.0/24'
		'TEST_HTTPS_URL=https://example.com'
		'TEST_HTTPS_URL=https://example.com/path?a=1&b=2'
		'EVEBOX_ES_URL=http://127.0.0.1:9200'
		'IFACES=enp2s0'
		'IFACES=eth0,eth1.100,br-lan'
		'BPF_FILTER=not (host 10.0.0.1 and port 443)'
		'HOME_NET=auto'
		'HOME_NET=10.0.0.0/8,192.168.0.0/16'
		'NGINX_CERT=/etc/ssl/certs/dpistack.pem'
		'RULES_SOURCES=et/open oisf/trafficid'
		'RULES_URLS=https://example.org/a.rules https://example.org/b.rules'
		'RULES_GROUPS=emerging-p2p,emerging-policy'
		'ALERT_MAIL_TO=a@example.com,b@example.com'
		'ALERT_CHANNELS=panel,log,tg,mail'
		'ALERT_TG_CHAT_ID=-1001234567890'
		'RULES_UPDATE_CALENDAR=*-*-* 03:00:00'
		'METRICS_RETENTION=30d'
	)
	for kv in "${good[@]}"; do
		KV="${kv#*=}" run bash -c "$PRE; schema_validate_one '${kv%%=*}' \"\$KV\""
		[ "$status" -eq 0 ] || {
			echo "rejected: $kv -> $output"
			return 1
		}
	done
}

@test "a rejected secret value is never echoed back" {
	KV='abc;def"ghi' run bash -c "$PRE; schema_validate_one ALERT_TG_TOKEN \"\$KV\""
	[ "$status" -eq 1 ]
	[[ "$output" != *"abc;def"* ]]
	KV='ftp://user:S3cret@host' run bash -c "$PRE; schema_validate_one ALERT_SMTP_URL \"\$KV\""
	[ "$status" -eq 1 ]
	[[ "$output" != *"S3cret"* ]]
}

@test "config-write refuses a secret key and a hostile LAN_CIDR, file stays unchanged" {
	conf="$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	mkdir -p "$(dirname "$conf")"
	printf 'IFACES=enp2s0\n' >"$conf"
	before="$(sha256sum "$conf" | cut -d' ' -f1)"
	run bash -c "printf 'ALERT_TG_TOKEN=123:abc\n' | '$CTL' config-write dpistack.conf"
	[ "$status" -eq 3 ]
	[[ "$output" == *"secrets.conf"* ]]
	run bash -c "printf 'LAN_CIDR=10.0.0.0/8; } server {\n' | '$CTL' config-write dpistack.conf"
	[ "$status" -eq 3 ]
	[ "$(sha256sum "$conf" | cut -d' ' -f1)" = "$before" ]
	# the secret must not appear anywhere in the output
	[[ "$output" != *"123:abc"* ]]
}

@test "logs -n: leading zeros are decimal and the limit cannot be bypassed" {
	shim="$(mktemp -d)"
	calls="$(mktemp)"
	export calls
	printf '#!/bin/sh\necho "$@" >>"$calls"\n' >"$shim/journalctl"
	printf '#!/bin/sh\ncase "$1" in show) echo loaded;; is-active) echo active;; *) exit 0;; esac\n' >"$shim/systemctl"
	chmod +x "$shim"/*
	PATH="$shim:$PATH" run "$CTL" logs suricata -n 08
	[ "$status" -eq 0 ]
	grep -q -- "-n 8 " "$calls"
	: >"$calls"
	PATH="$shim:$PATH" run "$CTL" logs suricata -n 01750
	[ "$status" -eq 2 ]
	[ ! -s "$calls" ]
	PATH="$shim:$PATH" run "$CTL" logs suricata -n 99999999999999999999
	[ "$status" -eq 2 ]
	rm -rf "$shim" "$calls"
}

@test "os_detect makes apt non-interactive" {
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	run env -u DEBIAN_FRONTEND bash -c "$PRE; os_detect 2>/dev/null; echo \"\$DEBIAN_FRONTEND\""
	[ "$output" = "noninteractive" ]
}

@test "config-write waits for the installer lock instead of racing it" {
	mkdir -p "$DPISTACK_ROOT/etc/dpistack" "$DPISTACK_ROOT/var/lock"
	printf 'IFACES=enp2s0\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	# Hold the lock the way a running install does, release it after 2 s.
	(
		exec 9>"$DPISTACK_ROOT/var/lock/dpistack.lock"
		flock 9
		sleep 2
	) &
	sleep 0.5
	start=$SECONDS
	run bash -c "printf 'IFACES=eth0\n' | '$CTL' config-write dpistack.conf"
	wait
	# Written only after the holder let go, and not refused.
	[ "$status" -eq 0 ]
	[ "$((SECONDS - start))" -ge 1 ]
	grep -q '^IFACES=eth0$' "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
}

@test "NTOPNG_VERSION and EVEBOX_VERSION pin the package that gets installed" {
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	# The mocks include ntopng and evebox binaries, which would make the
	# steps skip the install; leave those two out.
	mocks="$(mktemp -d)"
	cp "$REPO_DIR"/tests/mocks/* "$mocks/"
	rm -f "$mocks/ntopng" "$mocks/evebox"
	calls="$(mktemp)"
	PATH="$mocks:$PATH" MOCK_CALLS_LOG="$calls" MOCK_IP_EXISTING_IFACES=enp2s0 \
		bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no --set NTOPNG_VERSION=6.0 --set EVEBOX_VERSION=0.19.1 >/dev/null 2>&1 || true
	grep -q "apt-get install -y ntopng=6.0" "$calls"
	grep -q "apt-get install -y evebox=0.19.1" "$calls"
	rm -rf "$mocks" "$calls"
}
