#!/usr/bin/env bats
# The package-manager families (apt, dnf), the fallbacks between package
# and source builds, interface detection and pinned refs. The dnf paths
# run against mocks only: they are not verified on a real Fedora or RHEL
# host (tech.md 18.4).

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	DPISTACK_ROOT="$(mktemp -d)"
	export DPISTACK_ROOT
	CALLS="$(mktemp)"
	export CALLS
	mkdir -p "$DPISTACK_ROOT/etc"
}

teardown() {
	rm -rf "$DPISTACK_ROOT" "$CALLS"
}

# os_release <id> <id_like> <version_id>
os_release() {
	printf 'ID=%s\nID_LIKE="%s"\nVERSION_ID="%s"\nVERSION_CODENAME=bookworm\n' "$1" "$2" "$3" >"$DPISTACK_ROOT/etc/os-release"
}

# fam <script> - run a script with every lib loaded and the OS detected.
fam() {
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" bash -c "
		cd '$REPO_DIR'
		source lib/paths.sh; source lib/common.sh; source lib/state.sh; source lib/os.sh
		for f in lib/step_*.sh; do source \$f; done
		declare -A CONF=()
		os_detect >/dev/null 2>&1
		$1"
}

@test "dnf: one makecache before the first install" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'pkg_update_once; pkg_update_once'
	run grep -c '^dnf -y makecache' "$CALLS"
	[ "$output" = "1" ]
}

@test "dnf: only the missing base tools are installed" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'command() { if [[ "$1" == "-v" ]]; then case "$2" in curl | wget) return 0 ;; *) return 1 ;; esac; else builtin command "$@"; fi; }
		pkg_install_base' >/dev/null
	grep -q '^dnf install -y gnupg2 jq git openssl logrotate iproute sudo ca-certificates$' "$CALLS"
}

@test "dnf: nothing is installed when every base tool is there" {
	os_release fedora fedora 41
	fam 'command() { if [[ "$1" == "-v" ]]; then return 0; else builtin command "$@"; fi; }
		pkg_install_base' >/dev/null
	[ ! -s "$CALLS" ]
}

@test "dnf: Rocky 9 gets EPEL and crb, Rocky 8 powertools" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'pkg_enable_extra_repos' >/dev/null
	grep -q '^dnf install -y dnf-plugins-core epel-release$' "$CALLS"
	grep -q '^dnf config-manager --set-enabled crb$' "$CALLS"
	: >"$CALLS"
	os_release almalinux "rhel centos fedora" 8.10
	fam 'pkg_enable_extra_repos' >/dev/null
	grep -q '^dnf config-manager --set-enabled powertools$' "$CALLS"
}

@test "dnf: Fedora needs no extra repositories, RHEL gets EPEL and CodeReady Builder" {
	os_release fedora fedora 41
	fam 'pkg_enable_extra_repos' >/dev/null
	[ ! -s "$CALLS" ]
	os_release rhel "fedora" 9.4
	fam 'pkg_enable_extra_repos' >/dev/null
	grep -q '^dnf install -y dnf-plugins-core https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm$' "$CALLS"
	grep -q "^subscription-manager repos --enable=codeready-builder-for-rhel-9-$(uname -m)-rpms\$" "$CALLS"
}

@test "dnf: RHEL without a subscription still goes on, with a message" {
	os_release rhel "fedora" 9.4
	run fam 'subscription-manager() { return 1; }; pkg_enable_extra_repos'
	[ "$status" -eq 0 ]
	[[ "$output" == *"CodeReady Builder не включён"* ]]
}

@test "dnf: the build dependencies of Suricata and nDPI use the rpm names" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'pkg_build_deps suricata' >/dev/null
	grep -q '^dnf install -y gcc gcc-c++ make git autoconf automake libtool pkgconf-pkg-config libpcap-devel pcre2-devel libyaml-devel jansson-devel file-devel zlib-devel libcap-ng-devel libnet-devel lz4-devel python3-pyyaml cargo rust cbindgen$' "$CALLS"
	: >"$CALLS"
	fam 'pkg_build_deps ndpi' >/dev/null
	grep -q '^dnf install -y gcc gcc-c++ make git autoconf automake libtool pkgconf-pkg-config libpcap-devel$' "$CALLS"
}

@test "package names that differ between the families" {
	os_release rocky "rhel centos fedora" 9.4
	run fam 'echo "$NDPI_PACKAGE $REDIS_PACKAGE $REDIS_UNIT"'
	[ "$output" = "ndpi-devel redis redis.service" ]
	os_release ubuntu debian 24.04
	run fam 'echo "$NDPI_PACKAGE $REDIS_PACKAGE $REDIS_UNIT"'
	[ "$output" = "libndpi-dev redis-server redis-server.service" ]
}

@test "pkg_installed_version asks rpm on dnf and dpkg on apt" {
	os_release rocky "rhel centos fedora" 9.4
	run fam 'pkg_installed_version suricata'
	[ "$output" = "7.0.8-1" ]
	MOCK_RPM_ABSENT="suricata" run fam 'pkg_installed_version suricata'
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	os_release ubuntu debian 24.04
	run fam 'pkg_installed_version suricata'
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	MOCK_DPKG_ABSENT="suricata" run fam 'pkg_installed_version suricata'
	[ "$status" -eq 1 ]
}

@test "pkg_upgrade and pkg_pin per family" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'pkg_upgrade suricata redis; pkg_pin suricata' >/dev/null
	grep -q '^dnf upgrade -y suricata redis$' "$CALLS"
	grep -q '^dnf install -y python3-dnf-plugin-versionlock$' "$CALLS"
	grep -q '^dnf versionlock add suricata$' "$CALLS"
	: >"$CALLS"
	os_release ubuntu debian 24.04
	fam 'pkg_upgrade suricata; pkg_pin suricata' >/dev/null
	grep -q '^apt-get install --only-upgrade -y suricata$' "$CALLS"
	grep -q '^apt-mark hold suricata$' "$CALLS"
}

@test "ntopng on dnf: the ntop.org rpm repo on RHEL clones, the distribution on Fedora" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'ntopng_repo_add' >/dev/null
	grep -q "^curl -fsSL https://packages.ntop.org/centos-stable/ntop.repo -o $DPISTACK_ROOT/etc/yum.repos.d/ntop.repo\$" "$CALLS"
	grep -q '^dnf -y makecache$' "$CALLS"
	: >"$CALLS"
	os_release fedora fedora 41
	fam 'ntopng_repo_add' >/dev/null
	run grep -c '^curl' "$CALLS"
	[ "$output" = "0" ]
	MOCK_EXIT=1 run fam 'ntopng_repo_add'
	[ "$status" -eq 1 ]
	[[ "$output" == *"--skip ntopng"* ]]
}

@test "evebox on dnf: the stable repository comes from its release package, a failure names the way out" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'evebox_repo_add' >/dev/null
	grep -q '^dnf install -y https://evebox.org/files/rpm/stable/evebox-release.noarch.rpm$' "$CALLS"
	MOCK_EXIT=1 run fam 'evebox_repo_add'
	[ "$status" -eq 1 ]
	[[ "$output" == *"evebox.org/#downloads"* ]]
	[[ "$output" == *"--skip evebox"* ]]
}

@test "firewall: ufw where it exists, firewalld rich rules and a reload otherwise" {
	os_release ubuntu debian 24.04
	fam 'access_allow_port 10.0.0.0/24 3000' >/dev/null
	grep -q '^ufw allow from 10.0.0.0/24 to any port 3000 proto tcp$' "$CALLS"
	: >"$CALLS"
	os_release rocky "rhel centos fedora" 9.4
	fam 'command() { if [[ "$1" == "-v" && "$2" == "ufw" ]]; then return 1; else builtin command "$@"; fi; }
		CONF[FIREWALL_MANAGE]=auto; CONF[ACCESS_MODE]=lan
		access_allow_port 10.0.0.0/24 3000
		access_firewall_apply' >/dev/null
	grep -q '^firewall-cmd --permanent --add-rich-rule=rule family=ipv4 source address=10.0.0.0/24 port port=3000 protocol=tcp accept$' "$CALLS"
	grep -q '^firewall-cmd --reload$' "$CALLS"
}

@test "SELinux Enforcing with nginx turns on httpd_can_network_connect" {
	os_release rocky "rhel centos fedora" 9.4
	MOCK_GETENFORCE=Enforcing fam 'CONF[ACCESS_MODE]=nginx; access_selinux_notice' >/dev/null
	grep -q '^setsebool -P httpd_can_network_connect 1$' "$CALLS"
	: >"$CALLS"
	MOCK_GETENFORCE=Enforcing fam 'CONF[ACCESS_MODE]=lan; access_selinux_notice' >/dev/null
	[ ! -s "$CALLS" ]
}

@test "a dnf host is no longer a preflight failure" {
	os_release rocky "rhel centos fedora" 9.4
	run fam 'step_preflight_reasons'
	[[ "$output" != *"пока не поддерживается"* ]]
}

rust_case() {
	# rust_case <extra shell> - resolve with Suricata absent from dpkg
	os_release debian debian 12
	MOCK_DPKG_ABSENT="suricata" fam "CONF[SURICATA_SOURCE]=source; CONF[NDPI_ENABLE]=yes; $1
		suricata_resolve_source; rc=\$?; echo \"rc=\$rc source=\${CONF[SURICATA_SOURCE]} ndpi=\${CONF[NDPI_ENABLE]}\""
}

@test "no Rust 1.75 anywhere: the distribution package, nDPI off, a message" {
	run rust_case ''
	[[ "$output" == *"rc=0 source=distro ndpi=no"* ]]
	[[ "$output" == *"нужен Rust 1.75"* ]]
}

@test "a rustc-1.N package, a current rustc or a pinned version keep the source build" {
	MOCK_APT_RUSTC="85" run rust_case ''
	[[ "$output" == *"rc=1 source=source ndpi=yes"* ]]
	MOCK_RUSTC_VERSION=1.75.0 run rust_case ''
	[[ "$output" == *"rc=1 source=source ndpi=yes"* ]]
	MOCK_RUSTC_VERSION=1.90.0 run rust_case ''
	[[ "$output" == *"rc=1 source=source ndpi=yes"* ]]
	run rust_case 'CONF[SURICATA_VERSION]=suricata-8.0.1'
	[[ "$output" == *"rc=1 source=source ndpi=yes"* ]]
}

@test "no Rust and no suricata package: nothing to fall back to" {
	MOCK_APT_MISSING="suricata" run rust_case ''
	[[ "$output" == *"rc=1 source=source ndpi=yes"* ]]
}

@test "net_default_iface reads the default route, then sysfs" {
	os_release ubuntu debian 24.04
	mkdir -p "$DPISTACK_ROOT/proc/net" "$DPISTACK_ROOT/sys/class/net/lo" "$DPISTACK_ROOT/sys/class/net/veth0" "$DPISTACK_ROOT/sys/class/net/eth5"
	printf 'Iface\tDestination\tGateway\nlo\t0000007F\t00000000\neth9\t00000000\t0100A8C0\n' >"$DPISTACK_ROOT/proc/net/route"
	run fam 'net_default_iface'
	[ "$output" = "eth9" ]
	rm "$DPISTACK_ROOT/proc/net/route"
	touch "$DPISTACK_ROOT/sys/class/net/eth5/device"
	run fam 'net_default_iface'
	[ "$output" = "eth5" ]
	rm "$DPISTACK_ROOT/sys/class/net/eth5/device"
	run fam 'net_default_iface'
	[ "$output" = "eth5" ] || [ "$output" = "veth0" ]
}

@test "net_iface_exists falls back to sysfs when ip is not installed" {
	os_release ubuntu debian 24.04
	mkdir -p "$DPISTACK_ROOT/sys/class/net/eth7"
	run fam 'command() { if [[ "$1" == "-v" && "$2" == "ip" ]]; then return 1; else builtin command "$@"; fi; }
		net_iface_exists eth7 && echo yes; net_iface_exists nope || echo no'
	[ "${lines[-2]}" = "yes" ]
	[ "${lines[-1]}" = "no" ]
}

inst_dry() {
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" bash "$REPO_DIR/install.sh" install -y --dry-run --no-color "$@"
}

@test "the default IFACES that does not exist is replaced by the default-route interface" {
	os_release ubuntu debian 24.04
	mkdir -p "$DPISTACK_ROOT/proc/net"
	printf 'Iface\tDestination\tGateway\neth9\t00000000\t0100A8C0\n' >"$DPISTACK_ROOT/proc/net/route"
	MOCK_IP_EXISTING_IFACES=eth9 run inst_dry --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no --set TEST_ON_INSTALL=no
	[ "$status" -eq 0 ]
	[[ "$output" == *"интерфейса enp2s0 нет, взят eth9"* ]]
	[[ "$output" == *"IFACES=eth9"* ]]
}

@test "an IFACES value that was typed is never replaced" {
	os_release ubuntu debian 24.04
	mkdir -p "$DPISTACK_ROOT/proc/net"
	printf 'Iface\tDestination\tGateway\neth9\t00000000\t0100A8C0\n' >"$DPISTACK_ROOT/proc/net/route"
	MOCK_IP_EXISTING_IFACES=eth9 run inst_dry --set IFACES=nope --set SURICATA_SOURCE=distro --set NDPI_ENABLE=no
	[ "$status" -eq 3 ]
	[[ "$output" == *"интерфейс nope"* ]]
}

@test "nDPI: the default and a pinned version are compared as commits, not as text" {
	os_release ubuntu debian 24.04
	src="$DPISTACK_ROOT/usr/local/src/dpistack-ndpi"
	mkdir -p "$src" "$DPISTACK_ROOT/usr/local/lib"
	git -C "$src" init -q
	git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
	git -C "$src" tag 4.14
	git -C "$src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
	git -C "$src" tag 4.12 HEAD~1 2>/dev/null || true
	sha="$(git -C "$src" rev-parse 4.14^{commit})"
	touch "$DPISTACK_ROOT/usr/local/lib/libndpi.so"
	run fam "CONF[NDPI_ENABLE]=yes; CONF[NDPI_SOURCE]=source
		state_write_value \"\$(ndpi_built_ref_state_key)\" $sha
		step_ndpi_check && echo default-ok
		CONF[NDPI_VERSION]=4.14; step_ndpi_check && echo pinned-ok
		CONF[NDPI_VERSION]=nosuchtag; step_ndpi_check || echo unknown-rebuilds
		CONF[NDPI_VERSION]=; state_write_value \"\$(ndpi_built_ref_state_key)\" deadbeef; step_ndpi_check || echo stale-rebuilds"
	[[ "$output" == *"default-ok"* ]]
	[[ "$output" == *"pinned-ok"* ]]
	[[ "$output" == *"unknown-rebuilds"* ]]
	[[ "$output" == *"stale-rebuilds"* ]]
}

@test "Suricata without SURICATA_VERSION is the newest tested stable release, never master" {
	os_release ubuntu debian 24.04
	run fam 'suricata_target_ref; CONF[SURICATA_VERSION]=suricata-8.0.1; suricata_target_ref; echo "$SURICATA_STABLE_REF $SURICATA_COPR"'
	# Not the literal pin: it moves with every release the weekly watch accepts.
	[[ "${lines[-3]}" =~ ^suricata-[0-9]+\.[0-9]+\.[0-9]+$ ]]
	[ "${lines[-2]}" = "suricata-8.0.1" ]
	# The COPR series follows the pin: suricata-8.0.7 pairs with @oisf/suricata-8.0.
	[ "${lines[-1]}" = "${lines[-3]} @oisf/${lines[-3]%.*}" ]
}

sources_fixture() {
	mkdir -p "$DPISTACK_ROOT/etc/apt/sources.list.d"
	cat >"$DPISTACK_ROOT/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main non-free-firmware
deb-src http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main contrib
deb [signed-by=/usr/share/keyrings/x.gpg arch=amd64] http://deb.debian.org/debian bookworm-updates main
# deb http://deb.debian.org/debian commented main
deb https://packages.ntop.org/apt-stable/bookworm all main
EOF
	cat >"$DPISTACK_ROOT/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://example.com/repo
Suites: stable
Components: main
EOF
}

@test "apt_enable_component adds contrib to the Debian lines and stanzas only" {
	os_release debian debian 12
	sources_fixture
	fam 'apt_enable_component contrib' >/dev/null
	list="$DPISTACK_ROOT/etc/apt/sources.list"
	grep -q '^deb http://deb.debian.org/debian bookworm main non-free-firmware contrib$' "$list"
	grep -q '^deb-src http://deb.debian.org/debian bookworm main contrib$' "$list"
	grep -q '^deb http://security.debian.org/debian-security bookworm-security main contrib$' "$list"
	grep -q 'arch=amd64\] http://deb.debian.org/debian bookworm-updates main contrib$' "$list"
	grep -q '^# deb http://deb.debian.org/debian commented main$' "$list"
	grep -q '^deb https://packages.ntop.org/apt-stable/bookworm all main$' "$list"
	sources="$DPISTACK_ROOT/etc/apt/sources.list.d/debian.sources"
	grep -q '^Components: main contrib$' "$sources"
	[ "$(grep -c '^Components: main$' "$sources")" = "1" ]
}

@test "apt_enable_component is idempotent and keeps backups outside sources.list.d" {
	os_release debian debian 12
	sources_fixture
	fam 'apt_enable_component contrib' >/dev/null
	cp "$DPISTACK_ROOT/etc/apt/sources.list" "$DPISTACK_ROOT/after1"
	fam 'apt_enable_component contrib' >/dev/null
	cmp "$DPISTACK_ROOT/after1" "$DPISTACK_ROOT/etc/apt/sources.list"
	[ -n "$(ls "$DPISTACK_ROOT"/var/lib/dpistack/backups/ | grep '^sources.list.')" ]
	run ls "$DPISTACK_ROOT/etc/apt/sources.list.d"
	[ "$output" = "debian.sources" ]
}

@test "apt_enable_component honours dry-run" {
	os_release debian debian 12
	sources_fixture
	cp "$DPISTACK_ROOT/etc/apt/sources.list" "$DPISTACK_ROOT/before"
	run fam 'DRY_RUN=1; apt_enable_component contrib'
	[[ "$output" == *"+ enable contrib in"* ]]
	cmp "$DPISTACK_ROOT/before" "$DPISTACK_ROOT/etc/apt/sources.list"
}

@test "ntopng on Debian: contrib first, then the stable repo package" {
	os_release debian debian 12
	sources_fixture
	fam 'ntopng_repo_add' >/dev/null
	grep -q 'bookworm main non-free-firmware contrib$' "$DPISTACK_ROOT/etc/apt/sources.list"
	grep -q 'packages.ntop.org/apt-stable/bookworm/all/apt-ntop-stable.deb' "$CALLS"
	run grep -c 'add-apt-repository' "$CALLS"
	[ "$output" = "0" ]
}

@test "os_support_level: the supported platforms and the ones that are not" {
	check() {
		os_release "$1" "$2" "$3"
		run fam 'os_support_level'
		[ "$output" = "$4" ] || {
			echo "$1 $3: got $output want $4" >&2
			return 1
		}
	}
	check ubuntu debian 22.04 supported
	check ubuntu debian 24.04 supported
	check ubuntu debian 26.04 supported
	check ubuntu debian 28.04 supported
	check ubuntu debian 20.04 unsupported
	check ubuntu debian 18.04 unsupported
	check ubuntu debian 25.10 unverified
	check ubuntu debian 22.10 unverified
	check debian "" 12 supported
	check debian "" 13 supported
	check debian "" 14 supported
	check debian "" 11 unsupported
	check rocky "rhel centos fedora" 8.10 supported
	check rocky "rhel centos fedora" 9.5 supported
	check rocky "rhel centos fedora" 10.0 supported
	check almalinux "rhel centos fedora" 8.9 supported
	check almalinux "rhel centos fedora" 10.0 supported
	check rocky "rhel centos fedora" 7.9 unsupported
	check rhel "fedora" 9.4 unverified
	check rhel "fedora" 7.9 unsupported
	check centos "rhel fedora" 9 unverified
	check fedora "" 41 unverified
	check linuxmint "ubuntu debian" 22 unverified
	check debian "" sid unverified
}

preflight_reasons() {
	PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" bash -c "
		cd '$REPO_DIR'
		source lib/paths.sh; source lib/common.sh; source lib/state.sh; source lib/os.sh
		for f in lib/step_*.sh; do source \$f; done
		declare -A CONF=()
		os_detect >/dev/null 2>&1
		step_preflight_reasons" 2>&1
}

@test "preflight refuses an unsupported release and names the way around it" {
	os_release ubuntu debian 20.04
	run preflight_reasons
	[[ "$output" == *"ubuntu 20.04 не поддерживается"* ]]
	[[ "$output" == *"DPISTACK_ALLOW_UNSUPPORTED=1"* ]]
	DPISTACK_ALLOW_UNSUPPORTED=1 run preflight_reasons
	[[ "$output" != *"не поддерживается"* ]]
}

@test "preflight lets a supported release and warns about an unverified one" {
	os_release debian debian 12
	run preflight_reasons
	[[ "$output" != *"не поддерживается"* ]]
	[[ "$output" != *"не входит в список"* ]]
	os_release fedora fedora 41
	run preflight_reasons
	[[ "$output" == *"не входит в список проверенных платформ"* ]]
}

@test "dnf: the OISF COPR is enabled for SURICATA_SOURCE=oisf" {
	os_release rocky "rhel centos fedora" 9.4
	fam 'pkg_repo_add oisf' >/dev/null
	grep -q '^dnf install -y dnf-plugins-core$' "$CALLS"
	grep -q '^dnf copr enable -y @oisf/suricata-8.0$' "$CALLS"
}

@test "dnf without Rust 1.75 falls back to the OISF COPR package, nDPI off" {
	os_release rocky "rhel centos fedora" 9.4
	MOCK_DPKG_ABSENT="suricata" MOCK_RPM_ABSENT="suricata" run fam 'CONF[SURICATA_SOURCE]=source; CONF[NDPI_ENABLE]=yes
		suricata_resolve_source; echo "rc=$? source=${CONF[SURICATA_SOURCE]} ndpi=${CONF[NDPI_ENABLE]}"'
	[[ "$output" == *"rc=0 source=oisf ndpi=no"* ]]
}

@test "the RPM unit gets its options from /etc/sysconfig/suricata" {
	os_release rocky "rhel centos fedora" 9.4
	run fam 'suricata_render_sysconfig'
	[[ "$output" == *'OPTIONS="--af-packet --user suricata "'* ]]
	[[ "$output" == *"suricata.yaml"* ]]
}

@test "uninstall --purge removes the panel user" {
	os_release ubuntu debian 24.04
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	: >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	fakebin="$(mktemp -d)"
	printf '#!/usr/bin/env bash\n[[ "$1" == "dpistack" ]] && exit 0\nexec /usr/bin/id "$@"\n' >"$fakebin/id"
	chmod +x "$fakebin/id"
	PATH="$fakebin:$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" MOCK_IP_EXISTING_IFACES=enp2s0 \
		bash "$REPO_DIR/install.sh" uninstall -y --purge >/dev/null 2>&1 || true
	grep -q '^userdel dpistack$' "$CALLS"
	rm -rf "$fakebin"
}

@test "rules: a ruleset made for another Suricata version is rebuilt with --force" {
	os_release ubuntu debian 24.04
	script='CONF[RULES_SOURCES]=et/open; CONF[RULES_UPDATE]=off; step_rules_apply >/dev/null 2>&1; state_read_value rules.suricata_version'
	MOCK_SURICATA_VERSION=8.0.7 run fam "$script"
	[ "${lines[-1]}" = "8.0.7" ]
	grep -q '^suricata-update -D .* --force$' "$CALLS" || grep -q -- '--force' "$CALLS"
	: >"$CALLS"
	MOCK_SURICATA_VERSION=8.0.7 fam "$script" >/dev/null
	run grep -c -- '--force' "$CALLS"
	[ "$output" = "0" ]
	: >"$CALLS"
	MOCK_SURICATA_VERSION=8.0.8 run fam "$script"
	[ "${lines[-1]}" = "8.0.8" ]
	grep -q -- '--force' "$CALLS"
}

@test "rules: without a readable Suricata version nothing is forced" {
	os_release ubuntu debian 24.04
	fam 'CONF[RULES_SOURCES]=et/open; CONF[RULES_UPDATE]=off; step_rules_apply' >/dev/null 2>&1
	run grep -c -- '--force' "$CALLS"
	[ "$output" = "0" ]
}

@test "diag writes a report with its sections and hides secrets" {
	os_release ubuntu debian 24.04
	mkdir -p "$DPISTACK_ROOT/etc/dpistack"
	printf 'ALERT_SMTP_URL=smtp://user:s3cret@mail.example.com:587\nALERT_TG_TOKEN=12345:abcdef\nIFACES=eth0\n' >"$DPISTACK_ROOT/etc/dpistack/dpistack.conf"
	out="$DPISTACK_ROOT/diag.txt"
	run env PATH="$REPO_DIR/tests/mocks:$PATH" MOCK_CALLS_LOG="$CALLS" DIAG_OUT="$out" bash "$REPO_DIR/install.sh" diag --no-color
	[ "$status" -eq 0 ]
	[ -s "$out" ]
	grep -q '^===== платформа =====$' "$out"
	grep -q 'уровень=supported' "$out"
	grep -q '^===== dpistack.conf =====$' "$out"
	grep -q '^IFACES=eth0$' "$out"
	if grep -q 's3cret' "$out"; then false; fi
	if grep -q '12345:abcdef' "$out"; then false; fi
	grep -q '<скрыто>' "$out"
	[[ "$output" != *"s3cret"* ]]
}

@test "a Suricata rebuild does not run make install-conf over the rendered suricata.yaml (R134)" {
	os_release ubuntu debian 24.04
	local script='
		pkg_build_deps() { :; }; pkg_select_rust() { :; }
		run() { echo "RUN $*" >>"$MOCK_CALLS_LOG"; }
		mkdir -p "$(path_suricata_src_dir)/.git"
		suricata_build_from_source'
	fam "$script"
	grep -q '^RUN make install-conf$' "$CALLS"
	: >"$CALLS"
	mkdir -p "$(dirname "$DPISTACK_ROOT/etc/suricata/suricata.yaml")"
	echo rendered >"$DPISTACK_ROOT/etc/suricata/suricata.yaml"
	fam "$script"
	grep -q '^RUN make install$' "$CALLS"
	! grep -q 'install-conf' "$CALLS"
}

@test "PANEL_SOURCE=prebuilt: a reconfigure from the installed copy keeps the installed panel (R135)" {
	os_release ubuntu debian 24.04
	local script='
		ORIGIN_DIR="$DPISTACK_ROOT/copy"; mkdir -p "$ORIGIN_DIR"
		CONF[PANEL_SOURCE]=prebuilt
		mkdir -p "$(dirname "$(path_panel_bin)")"; : >"$(path_panel_bin)"; chmod 755 "$(path_panel_bin)"
		panel_bin_current && echo current'
	run fam "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *current* ]]
	local script2='
		ORIGIN_DIR="$DPISTACK_ROOT/copy"; mkdir -p "$ORIGIN_DIR"
		CONF[PANEL_SOURCE]=prebuilt
		echo new >"$ORIGIN_DIR/dpistack-panel"
		mkdir -p "$(dirname "$(path_panel_bin)")"; echo old >"$(path_panel_bin)"; chmod 755 "$(path_panel_bin)"
		panel_bin_current || echo differs'
	run fam "$script2"
	[[ "$output" == *differs* ]]
}
