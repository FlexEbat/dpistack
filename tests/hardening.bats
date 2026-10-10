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
	printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\n' >"$DPISTACK_ROOT/etc/os-release"
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

@test "security.sh fails when git cannot list the files, instead of scanning nothing" {
	work="$(mktemp -d)"
	mkdir -p "$work/scripts" "$work/lib" "$work/bin"
	cp "$REPO_DIR/scripts/security.sh" "$work/scripts/"
	echo '#!/usr/bin/env bash' >"$work/install.sh"
	# Not a git repository: git ls-files fails, which used to mean "no files, all clear".
	run env GIT_CEILING_DIRECTORIES="$work/.." bash "$work/scripts/security.sh"
	rm -rf "$work"
	[ "$status" -eq 1 ]
	[[ "$output" == *"git ls-files returned no files"* ]]
}

@test "atomic_write keeps the mode of an existing file and gives a new file 0644" {
	target="$DPISTACK_ROOT/etc/app.conf"
	mkdir -p "$DPISTACK_ROOT/etc"
	echo old >"$target"
	chmod 0640 "$target"
	lib "echo new | atomic_write '$target'"
	[ "$(stat -c %a "$target")" = "640" ]
	[ "$(cat "$target")" = "new" ]
	lib "echo fresh | atomic_write '$DPISTACK_ROOT/etc/fresh.conf'"
	[ "$(stat -c %a "$DPISTACK_ROOT/etc/fresh.conf")" = "644" ]
}

@test "atomic_write with an explicit mode never exposes the content wider" {
	target="$DPISTACK_ROOT/etc/secret.conf"
	mkdir -p "$DPISTACK_ROOT/etc"
	echo old >"$target"
	chmod 0644 "$target"
	lib "echo new | atomic_write '$target' 0640"
	[ "$(stat -c %a "$target")" = "640" ]
	lib "echo newer | atomic_write '$target' 0600"
	[ "$(stat -c %a "$target")" = "600" ]
}

@test "a rendered config file is world-readable, not 0600 from mktemp" {
	mkdir -p "$DPISTACK_ROOT/etc" "$DPISTACK_ROOT/etc/evebox"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$(mktemp)" MOCK_IP_EXISTING_IFACES=enp2s0 \
		bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no >/dev/null 2>&1 || true
	[ "$(stat -c %a "$DPISTACK_ROOT/etc/evebox/evebox.yaml")" = "644" ]
	[ "$(stat -c %a "$DPISTACK_ROOT/etc/dpistack/secrets.conf")" = "600" ]
}

@test "a failing systemctl enable stops the install instead of reporting the step as done" {
	mkdir -p "$DPISTACK_ROOT/etc" "$DPISTACK_ROOT/fake"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	cat >"$DPISTACK_ROOT/fake/systemctl" <<'EOF_FAKE'
#!/usr/bin/env bash
[[ "$*" == *enable*evebox* ]] && exit 1
exit 0
EOF_FAKE
	chmod +x "$DPISTACK_ROOT/fake/systemctl"
	PATH="$DPISTACK_ROOT/fake:$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$(mktemp)" MOCK_IP_EXISTING_IFACES=enp2s0 \
		run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no
	[ "$status" -eq 1 ]
	[[ "$output" == *"шаг evebox упал"* ]]
}

@test "the redis step does not record done when the service fails to start" {
	mkdir -p "$DPISTACK_ROOT/etc" "$DPISTACK_ROOT/fake"
	printf 'ID=ubuntu\nID_LIKE=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	printf '#!/usr/bin/env bash\n[[ "$*" == *enable*redis* ]] && exit 1\nexit 0\n' >"$DPISTACK_ROOT/fake/systemctl"
	chmod +x "$DPISTACK_ROOT/fake/systemctl"
	PATH="$DPISTACK_ROOT/fake:$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$(mktemp)" MOCK_IP_EXISTING_IFACES=enp2s0 \
		run bash "$REPO_DIR/install.sh" install -y --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no \
		--set TEST_ON_INSTALL=no
	[ "$status" -eq 1 ]
	run lib 'state_read_value step.redis.status'
	[ "$output" != "done" ]
}

@test "ntopng repo setup: universe and the version path on Ubuntu, release name on Debian" {
	mkdir -p "$DPISTACK_ROOT/etc"
	mocks="$(mktemp -d)"
	cp "$REPO_DIR"/tests/mocks/* "$mocks/"
	rm -f "$mocks/ntopng"
	for id in ubuntu debian; do
		if [ "$id" = ubuntu ]; then
			printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$DPISTACK_ROOT/etc/os-release"
		else
			printf 'ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n' >"$DPISTACK_ROOT/etc/os-release"
		fi
		calls="$(mktemp)"
		PATH="$mocks:$PATH" MOCK_CALLS_LOG="$calls" bash -c "
			source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/state.sh'
			source '$REPO_DIR/lib/os.sh'; source '$REPO_DIR/lib/step_ntopng.sh'
			os_detect >/dev/null 2>&1; ntopng_repo_add >/dev/null 2>&1"
		if [ "$id" = ubuntu ]; then
			grep -q "add-apt-repository -y universe" "$calls"
			grep -q "packages.ntop.org/apt/24.04/all/apt-ntop.deb" "$calls"
		else
			run grep -c "add-apt-repository" "$calls"
			[ "$output" = "0" ]
			grep -q "packages.ntop.org/apt/bookworm/all/apt-ntop.deb" "$calls"
		fi
		rm -f "$calls"
	done
	rm -rf "$mocks"
}

@test "ntopng repo setup stops when os-release names no release" {
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=debian\n' >"$DPISTACK_ROOT/etc/os-release"
	calls="$(mktemp)"
	run env PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$calls" bash -c "
		source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/state.sh'
		source '$REPO_DIR/lib/os.sh'; source '$REPO_DIR/lib/step_ntopng.sh'
		os_detect >/dev/null 2>&1; ntopng_repo_add"
	[ "$status" -eq 1 ]
	run grep -c "wget" "$calls"
	[ "$output" = "0" ]
	rm -f "$calls"
}

@test "config_snapshot_applied waits for the state lock like state_write_value" {
	mkdir -p "$DPISTACK_ROOT/var/lib/dpistack"
	state="$(lib 'path_state_file')"
	mkdir -p "$(dirname "$state")"
	flock -x "${state}.lock" sleep 3 &
	holder=$!
	sleep 0.3
	run timeout 1 bash -c "$PRE; source '$REPO_DIR/lib/config.sh'; declare -A CONF=([A]=1); config_snapshot_applied"
	kill "$holder" 2>/dev/null || true
	wait "$holder" 2>/dev/null || true
	[ "$status" -eq 124 ]
}

ubuntu_root() {
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$DPISTACK_ROOT/etc/os-release"
	CALLS="$(mktemp)"
	export CALLS
}

inst() {
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" MOCK_IP_EXISTING_IFACES=enp2s0 \
		bash "$REPO_DIR/install.sh" "$@"
}

@test "install refreshes the package index once, before the first install, and installs the base tools" {
	ubuntu_root
	inst install -y --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no >/dev/null 2>&1 || true
	first="$(grep '^apt-get' "$CALLS" | head -n 1)"
	[ "$first" = "apt-get update" ]
	update_line="$(grep -n '^apt-get update' "$CALLS" | head -n 1 | cut -d: -f1)"
	install_line="$(grep -n '^apt-get install' "$CALLS" | head -n 1 | cut -d: -f1)"
	[ "$update_line" -lt "$install_line" ]
	grep -q '^apt-get install -y ca-certificates curl wget gnupg jq git openssl logrotate software-properties-common$' "$CALLS"
}

@test "a missing suricata package switches the run to a source build and saves it" {
	ubuntu_root
	MOCK_DPKG_ABSENT="suricata" MOCK_APT_MISSING="suricata" run inst install -y --dry-run --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"пакета suricata нет в репозиториях"* ]]
	[[ "$output" == *"suricata: сборка из исходников"* ]]
}

@test "the source switch is written to dpistack.conf outside dry-run" {
	ubuntu_root
	MOCK_DPKG_ABSENT="suricata" MOCK_APT_MISSING="suricata" inst install -y --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no >/dev/null 2>&1 || true
	grep -q '^SURICATA_SOURCE=source$' "$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	grep -q '^apt-get install -y build-essential git autoconf' "$CALLS"
}

@test "oisf on Debian switches to a source build instead of failing on add-apt-repository" {
	mkdir -p "$DPISTACK_ROOT/etc"
	printf 'ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n' >"$DPISTACK_ROOT/etc/os-release"
	CALLS="$(mktemp)"
	MOCK_DPKG_ABSENT="suricata" run inst install -y --dry-run --set SURICATA_SOURCE=oisf --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[[ "$output" == *"PPA OISF существует только для Ubuntu"* ]]
	[[ "$output" != *"add-apt-repository -y ppa:oisf"* ]]
}

@test "a missing libndpi-dev switches NDPI_SOURCE=pkg to a source build" {
	ubuntu_root
	MOCK_DPKG_ABSENT="libndpi-dev" MOCK_APT_MISSING="libndpi-dev" run inst install -y --dry-run --set SURICATA_SOURCE=source \
		--set NDPI_ENABLE=yes --set NDPI_SOURCE=pkg --set TEST_ON_INSTALL=no
	[[ "$output" == *"пакета libndpi-dev нет в репозиториях"* ]]
	[[ "$output" == *"ndpi: сборка из исходников"* ]]
}

@test "a present package keeps the chosen source" {
	ubuntu_root
	run inst install -y --dry-run --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[[ "$output" != *"заменён на source"* ]]
	[[ "$output" == *"suricata: установка/обновление пакета"* ]]
}

@test "the source build picks a versioned rustc when the default one is too old" {
	ubuntu_root
	run env PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" MOCK_APT_RUSTC="83 85 89" bash -c "
		source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/state.sh'
		source '$REPO_DIR/lib/os.sh'; os_detect >/dev/null 2>&1
		pkg_select_rust && echo \"RUSTC=\$RUSTC CARGO=\$CARGO\""
	[ "$status" -eq 0 ]
	[[ "$output" == *"RUSTC=rustc-1.85 CARGO=cargo-1.85"* ]]
	grep -q 'apt-get install -y rustc-1.85 cargo-1.85' "$CALLS"
}

@test "no newer rustc package: a warning, nothing installed, the build is left to configure" {
	ubuntu_root
	run env PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" bash -c "
		source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/state.sh'
		source '$REPO_DIR/lib/os.sh'; os_detect >/dev/null 2>&1
		pkg_select_rust"
	[ "$status" -eq 0 ]
	[[ "$output" == *"старше 1.85"* ]]
	run grep -c 'apt-get install' "$CALLS"
	[ "$output" = "0" ]
}

@test "a current rustc is used as it is" {
	ubuntu_root
	run env PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" MOCK_RUSTC_VERSION=1.90.0 MOCK_APT_RUSTC="85" bash -c "
		source '$REPO_DIR/lib/paths.sh'; source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/state.sh'
		source '$REPO_DIR/lib/os.sh'; os_detect >/dev/null 2>&1
		pkg_select_rust"
	[ "$status" -eq 0 ]
	run grep -c 'apt-get install' "$CALLS"
	[ "$output" = "0" ]
}

@test "upgrade refreshes the package index before --only-upgrade and fails when apt fails" {
	ubuntu_root
	inst install -y --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no >/dev/null 2>&1 || true
	: >"$CALLS"
	inst upgrade >/dev/null 2>&1
	[ "$(grep '^apt-get' "$CALLS" | head -n 1)" = "apt-get update" ]
	grep -q 'apt-get install --only-upgrade' "$CALLS"
	MOCK_EXIT=100 run inst upgrade
	[ "$status" -eq 1 ]
}
