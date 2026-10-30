#!/usr/bin/env bash
# OS detection and package-manager wrappers. Steps call pkg_install,
# never apt-get/dnf directly (tech.md section 3).

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_FAMILY=""

# Family for a given (id, id_like) pair. ID wins; ID_LIKE is consulted
# for derivatives that do not use their upstream name as ID (tests
# exercise this through stub os-release files).
os_family_for() {
	local id="$1" id_like="$2"
	case " $id $id_like " in
	*" ubuntu "* | *" debian "*)
		echo "apt"
		return
		;;
	*" fedora "* | *" rhel "* | *" centos "*)
		echo "dnf"
		return
		;;
	*" opensuse"* | *" suse "* | *" sles "* | *" sled "*)
		echo "zypper"
		return
		;;
	*" arch "* | *" archlinux "* | *" manjaro "* | *" endeavouros "*)
		echo "pacman"
		return
		;;
	esac
	# Any other Linux: no package manager of its own is driven. Components
	# run in Docker, the installer needs systemd and a few base tools.
	echo "generic"
}

os_detect() {
	local f
	f=$(path_os_release)
	if [[ ! -r "$f" ]]; then
		die 3 "cannot read $f, unsupported or broken system"
	fi

	# shellcheck disable=SC1090
	OS_ID=$(. "$f" && echo "${ID:-}")
	# shellcheck disable=SC1090
	OS_ID_LIKE=$(. "$f" && echo "${ID_LIKE:-}")
	# shellcheck disable=SC1090
	OS_VERSION_ID=$(. "$f" && echo "${VERSION_ID:-}")

	OS_FAMILY=$(os_family_for "$OS_ID" "$OS_ID_LIKE")

	# dpistack manages its services as systemd units, on every family.
	if [[ "$OS_FAMILY" == "generic" && ! -d "$(path_systemd_marker)" ]]; then
		die 3 "$OS_ID: systemd is needed (no $(path_systemd_marker)); dpistack does not work on systems with another init"
	fi

	log "INFO" "detected $OS_ID $OS_VERSION_ID, family=$OS_FAMILY"
	# apt must never stop on a debconf or needrestart question: the
	# installer may run with no terminal (-y, a timer, a pipe).
	if [[ "$OS_FAMILY" == "apt" ]]; then
		export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
	fi
	# Package and unit names that differ between the families.
	if [[ "$OS_FAMILY" == "dnf" ]]; then
		# These are read by step_ndpi.sh and step_redis.sh.
		# shellcheck disable=SC2034
		NDPI_PACKAGE="ndpi-devel"
		# shellcheck disable=SC2034
		REDIS_PACKAGE="redis"
		# shellcheck disable=SC2034
		REDIS_UNIT="redis.service"
	fi
}

pkg_install() {
	# pkg_install <package...>
	case "$OS_FAMILY" in
	apt)
		run apt-get install -y "$@"
		;;
	dnf)
		run dnf install -y "$@"
		;;
	zypper)
		run zypper --non-interactive install --no-recommends "$@"
		;;
	pacman)
		run pacman -S --noconfirm --needed "$@"
		;;
	generic)
		echo "$OS_ID: the installer does not install packages on this distribution; install them by hand: $*" >&2
		return 1
		;;
	*)
		die 3 "pkg_install called before os_detect (family=$OS_FAMILY)"
		;;
	esac
}

# pkg_spec <package> [version] - the argument that pins a package to a
# version (NTOPNG_VERSION, EVEBOX_VERSION); no version means the latest.
pkg_spec() {
	local pkg="$1" version="${2:-}"
	if [[ -z "$version" ]]; then
		echo "$pkg"
		return
	fi
	case "$OS_FAMILY" in
	apt) echo "${pkg}=${version}" ;;
	dnf) echo "${pkg}-${version}" ;;
	*) echo "$pkg" ;;
	esac
}

# The OISF COPR series that matches SURICATA_STABLE_REF.
SURICATA_COPR="@oisf/suricata-8.0"

pkg_repo_add() {
	# pkg_repo_add <name>
	# Only "oisf" exists as a named repo (tech.md 4.3 SURICATA_SOURCE=oisf):
	# the OISF PPA on Ubuntu, the OISF COPR on the RHEL family and Fedora.
	local name="$1"
	case "$OS_FAMILY:$name" in
	apt:oisf)
		run add-apt-repository -y ppa:oisf/suricata-stable
		run apt-get update
		;;
	dnf:oisf)
		pkg_install dnf-plugins-core || return 1
		run dnf copr enable -y "$SURICATA_COPR" || return 1
		run dnf -y makecache
		;;
	*)
		die 3 "pkg_repo_add: unknown combination family=$OS_FAMILY repo=$name"
		;;
	esac
}

pkg_pin() {
	# pkg_pin <package>
	case "$OS_FAMILY" in
	apt)
		run apt-mark hold "$1"
		;;
	dnf)
		pkg_install python3-dnf-plugin-versionlock || return 1
		run dnf versionlock add "$1"
		;;
	zypper)
		run zypper --non-interactive addlock "$1"
		;;
	*)
		echo "$OS_ID: pinning the version of package $1 is not supported here (PIN_VERSIONS skipped)" >&2
		;;
	esac
}

# pkg_installed_version <package> - the installed version, empty (and rc 1)
# when the package is not installed.
pkg_installed_version() {
	local out
	case "$OS_FAMILY" in
	apt) out=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null) || return 1 ;;
	dnf | zypper) out=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null) || return 1 ;;
	pacman) out=$(pacman -Q "$1" 2>/dev/null | awk '{print $2}') && [[ -n "$out" ]] || return 1 ;;
	*) return 1 ;;
	esac
	printf '%s' "$out"
}

# pkg_upgrade <package...> - upgrade only what is already installed.
pkg_upgrade() {
	case "$OS_FAMILY" in
	apt) run apt-get install --only-upgrade -y "$@" ;;
	dnf) run dnf upgrade -y "$@" ;;
	zypper) run zypper --non-interactive update "$@" ;;
	pacman) run pacman -S --noconfirm --needed "$@" ;;
	*) return 1 ;;
	esac
}

# One package index refresh per run, before the first install: a fresh
# image has no lists and apt-get install cannot find anything.
# Repository steps still refresh again after they add a source.
PKG_INDEX_FRESH=0
pkg_update_once() {
	[[ "$PKG_INDEX_FRESH" == "1" ]] && return 0
	case "$OS_FAMILY" in
	apt) run apt-get update || return 1 ;;
	dnf) run dnf -y makecache || return 1 ;;
	zypper) run zypper --non-interactive refresh || return 1 ;;
	pacman)
		# a bare -Sy is a partial upgrade, which Arch documents as unsupported
		;;
	esac
	PKG_INDEX_FRESH=1
}

# pkg_available <package> - the package has an installable candidate.
pkg_available() {
	case "$OS_FAMILY" in
	apt)
		local candidate
		candidate=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
		[[ -n "$candidate" && "$candidate" != "(none)" ]]
		;;
	dnf) dnf -q list --available "$1" >/dev/null 2>&1 ;;
	zypper) zypper --non-interactive info "$1" >/dev/null 2>&1 ;;
	pacman) pacman -Si "$1" >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# Tools the steps call directly: curl and wget for keys and repos, gnupg
# for apt keys, jq for the watchdog, openssl for the self-signed
# certificate, logrotate for the Suricata rotation file, git for
# source builds, sudo (visudo) for the panel rule. A minimal image has none of them.
pkg_install_base() {
	case "$OS_FAMILY" in
	apt)
		local -a pkgs=(ca-certificates curl wget gnupg jq git openssl logrotate iproute2 sudo)
		# add-apt-repository (OISF PPA, universe) comes from this package.
		[[ "$OS_ID" == "ubuntu" ]] && pkgs+=(software-properties-common)
		pkg_install "${pkgs[@]}"
		;;
	dnf)
		# Only what is missing: on RHEL 9 the curl binary comes from
		# curl-minimal and installing curl next to it is a conflict.
		local -a missing=()
		local pair
		for pair in curl:curl wget:wget gpg:gnupg2 jq:jq git:git openssl:openssl \
			logrotate:logrotate ip:iproute visudo:sudo update-ca-trust:ca-certificates; do
			command -v "${pair%%:*}" >/dev/null 2>&1 || missing+=("${pair##*:}")
		done
		[[ "${#missing[@]}" -eq 0 ]] || pkg_install "${missing[@]}"
		;;
	zypper | pacman)
		local -a missing=()
		local pair gpgpkg=gnupg gitpkg=git
		[[ "$OS_FAMILY" == "zypper" ]] && gpgpkg=gpg2 && gitpkg=git-core
		for pair in curl:curl wget:wget gpg:"$gpgpkg" jq:jq git:"$gitpkg" openssl:openssl \
			logrotate:logrotate ip:iproute2 visudo:sudo; do
			command -v "${pair%%:*}" >/dev/null 2>&1 || missing+=("${pair##*:}")
		done
		[[ "${#missing[@]}" -eq 0 ]] || pkg_install "${missing[@]}"
		;;
	generic)
		# The Docker runtimes need little from the host: the commands the
		# steps call themselves. They are not installed for the person.
		local -a lacking=()
		local c
		for c in ip visudo openssl jq; do
			command -v "$c" >/dev/null 2>&1 || lacking+=("$c")
		done
		if [[ "${#lacking[@]}" -gt 0 ]]; then
			echo "$OS_ID: commands not found: ${lacking[*]}; install them with the distribution packages and repeat" >&2
			return 1
		fi
		;;
	esac
}

# pkg_enable_extra_repos - the RHEL clones keep Suricata, redis and the
# -devel packages in EPEL and CodeReady Builder. Fedora and Amazon Linux
# need nothing; RHEL itself needs a subscription, so it is left to the
# administrator with a clear message.
pkg_enable_extra_repos() {
	[[ "$OS_FAMILY" == "dnf" ]] || return 0
	local major="${OS_VERSION_ID%%.*}" repo=crb
	case "$OS_ID" in
	fedora | amzn) return 0 ;;
	rocky | almalinux | centos)
		pkg_install dnf-plugins-core epel-release || return 1
		[[ "$major" =~ ^[0-9]+$ ]] && ((major <= 8)) && repo=powertools
		run dnf config-manager --set-enabled "$repo" || return 1
		;;
	rhel)
		# EPEL from the Fedora project; CodeReady Builder needs a
		# subscribed system. A system without one still installs the
		# packages, only the -devel libraries for a source build are
		# missing, and that fails with a clear message later.
		pkg_install dnf-plugins-core "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm" || return 1
		run subscription-manager repos "--enable=codeready-builder-for-rhel-${major}-$(uname -m)-rpms" ||
			echo "rhel: the CodeReady Builder repository is not enabled (a subscription is needed); enable it by hand to build from source" >&2
		;;
	*)
		echo "$OS_ID: enable EPEL and the -devel repository by hand, the installer does not touch them" >&2
		;;
	esac
}

# pkg_build_deps <suricata|ndpi> - compilers and libraries a source
# build needs; without them autogen.sh fails on a clean image.
pkg_build_deps() {
	case "$OS_FAMILY" in
	apt)
		local -a pkgs=(build-essential git autoconf automake libtool pkg-config make libpcap-dev)
		if [[ "$1" == "suricata" ]]; then
			pkgs+=(libpcre2-dev libyaml-dev libjansson-dev libmagic-dev zlib1g-dev
				libcap-ng-dev libnet1-dev liblz4-dev python3-yaml cargo rustc)
			# A git checkout generates its Rust headers with cbindgen.
			pkg_available cbindgen && pkgs+=(cbindgen)
		fi
		pkg_install "${pkgs[@]}"
		;;
	dnf)
		local -a pkgs=(gcc gcc-c++ make git autoconf automake libtool pkgconf-pkg-config libpcap-devel)
		if [[ "$1" == "suricata" ]]; then
			pkgs+=(pcre2-devel libyaml-devel jansson-devel file-devel zlib-devel
				libcap-ng-devel libnet-devel lz4-devel python3-pyyaml cargo rust)
			pkg_available cbindgen && pkgs+=(cbindgen)
		fi
		pkg_install "${pkgs[@]}"
		;;
	*)
		die 3 "pkg_build_deps: unknown package family: $OS_FAMILY"
		;;
	esac
}

# Suricata 8.0 needs Rust 1.75. Ubuntu keeps rustc-1.N packages next to the
# default one; OISF documents RUSTC/CARGO for ./configure
# to pick them. On a distro with nothing newer configure prints its own
# message and the step stops there.
# Rust 1.75 is the MSRV of the Suricata 8.0 releases (configure.ac).
SURICATA_RUST_MIN_MINOR=75

# pkg_rust_versioned_minor - the smallest N >= 85 for which the apt
# repositories carry rustc-1.N; empty when there is none.
pkg_rust_versioned_minor() {
	apt-cache pkgnames rustc-1. 2>/dev/null | sed -n 's/^rustc-1\.\([0-9][0-9]*\)$/\1/p' |
		awk -v m="$SURICATA_RUST_MIN_MINOR" '$1 >= m' | sort -n | head -n 1
}

# pkg_rust_default_minor - N of the 1.N version of the unversioned
# `rustc` package the apt repositories would install (Debian 13 has
# 1.85 there, no rustc-1.N packages); empty when there is none.
pkg_rust_default_minor() {
	apt-cache policy rustc 2>/dev/null |
		sed -n 's/^ *Candidate: \([0-9][0-9]*:\)\{0,1\}1\.\([0-9][0-9]*\)\..*/\2/p' | head -n 1
}

# pkg_rust_default_ok - the unversioned rustc/cargo of the apt
# repositories is new enough for Suricata.
pkg_rust_default_ok() {
	local minor
	minor=$(pkg_rust_default_minor)
	((${minor:-0} >= SURICATA_RUST_MIN_MINOR))
}

# pkg_rust_obtainable - a Rust new enough for Suricata from git is
# installed or can be installed from the repositories.
pkg_rust_obtainable() {
	local have
	have=$(rustc --version 2>/dev/null | sed -n 's/^rustc 1\.\([0-9][0-9]*\)\..*/\1/p')
	((${have:-0} >= SURICATA_RUST_MIN_MINOR)) && return 0
	case "$OS_FAMILY" in
	apt) pkg_rust_default_ok || [[ -n "$(pkg_rust_versioned_minor)" ]] ;;
	dnf)
		have=$(dnf -q repoquery --latest-limit=1 --qf '%{version}' rust 2>/dev/null |
			sed -n 's/^1\.\([0-9][0-9]*\)\..*/\1/p' | head -n 1)
		((${have:-0} >= SURICATA_RUST_MIN_MINOR))
		;;
	*) return 1 ;;
	esac
}

pkg_select_rust() {
	[[ "$DRY_RUN" == "1" ]] && return 0
	local have wanted
	have=$(rustc --version 2>/dev/null | sed -n 's/^rustc 1\.\([0-9][0-9]*\)\..*/\1/p')
	((${have:-0} >= SURICATA_RUST_MIN_MINOR)) && return 0
	# The default packages first: where they are new enough (Debian 13)
	# the build uses the ordinary `rustc` and `cargo`.
	if [[ "$OS_FAMILY" == "apt" ]] && pkg_rust_default_ok; then
		pkg_install rustc cargo || return 1
		return 0
	fi
	wanted=$(pkg_rust_versioned_minor)
	if [[ -z "$wanted" ]]; then
		echo "suricata: rustc 1.${have:-?} is older than 1.${SURICATA_RUST_MIN_MINOR}, there are no newer rustc-1.N packages in the repositories; the build may fail at configure (then use SURICATA_SOURCE=oisf or distro)" >&2
		return 0
	fi
	pkg_install "rustc-1.$wanted" "cargo-1.$wanted" || return 1
	export RUSTC="rustc-1.$wanted" CARGO="cargo-1.$wanted"
}

# net_iface_exists <name> - the interface is there. Uses ip when it is
# installed and sysfs otherwise: a minimal image has no iproute2 yet.
net_iface_exists() {
	if command -v ip >/dev/null 2>&1; then
		ip link show "$1" >/dev/null 2>&1
	else
		[[ -e "$(path_sys_class_net)/$1" ]]
	fi
}

# net_default_iface - the interface of the default route, else the first
# non-loopback interface that has a device behind it, else the first
# non-loopback one; empty when there is none. Read from /proc and sysfs,
# so it works before iproute2 is installed.
net_default_iface() {
	local found="" dir
	if [[ -r "$(path_proc_net_route)" ]]; then
		found=$(awk 'NR > 1 && $2 == "00000000" {print $1; exit}' "$(path_proc_net_route)")
	fi
	dir=$(path_sys_class_net)
	if [[ -z "$found" && -d "$dir" ]]; then
		local candidate
		for candidate in "$dir"/*; do
			[[ "${candidate##*/}" == "lo" ]] && continue
			if [[ -e "$candidate/device" ]]; then
				found="${candidate##*/}"
				break
			fi
		done
		if [[ -z "$found" ]]; then
			for candidate in "$dir"/*; do
				[[ -e "$candidate" && "${candidate##*/}" != "lo" ]] || continue
				found="${candidate##*/}"
				break
			done
		fi
	fi
	printf '%s' "$found"
}

# os_support_level - "supported", "unverified" or "unsupported" for this
# system. Supported: Ubuntu LTS from 22.04, Debian from 12, Rocky Linux and
# AlmaLinux from 8. Anything older of those is unsupported. Anything else
# of a known family (RHEL and CentOS Stream until they become a target, an
# interim Ubuntu, Fedora, Mint) is tried with a warning.
os_support_level() {
	local major="${OS_VERSION_ID%%.*}" minor="${OS_VERSION_ID#*.}"
	if [[ ! "$major" =~ ^[0-9]+$ ]]; then
		echo unverified
		return
	fi
	case "$OS_FAMILY:$OS_ID" in
	apt:ubuntu)
		if ((major < 22)); then
			echo unsupported
		elif [[ "$minor" == "04" ]] && ((major % 2 == 0)); then
			echo supported
		else
			echo unverified
		fi
		;;
	apt:debian)
		if ((major >= 12)); then echo supported; else echo unsupported; fi
		;;
	dnf:rocky | dnf:almalinux)
		if ((major >= 8)); then echo supported; else echo unsupported; fi
		;;
	dnf:rhel | dnf:centos)
		if ((major >= 8)); then echo unverified; else echo unsupported; fi
		;;
	*) echo unverified ;;
	esac
}

# apt_enable_component <component> - add a component such as contrib to
# the Debian archives in the sources, in the one-line format
# (sources.list, *.list) and in deb822 (*.sources). Only lines and
# stanzas that point at a debian.org host are touched, each changed file
# is copied to the backups directory first (apt warns about stray files in
# sources.list.d), and a second call changes nothing.
apt_enable_component() {
	local comp="$1" f dir changed=0
	dir=$(path_apt_dir)
	for f in "$dir/sources.list" "$dir"/sources.list.d/*.list "$dir"/sources.list.d/*.sources; do
		[[ -f "$f" ]] || continue
		local tmp
		tmp=$(mktemp)
		awk -v comp="$comp" '
			function has(list, word,    n, a, i) {
				n = split(list, a, /[ \t]+/)
				for (i = 1; i <= n; i++) if (a[i] == word) return 1
				return 0
			}
			/^(deb|deb-src)[ \t]/ && /debian\.org|debian\.net/ {
				# deb [opts] URI suite comp1 comp2 ...
				line = $0; sub(/\[[^]]*\][ \t]*/, "", line)
				n = split(line, w, /[ \t]+/)
				if (n >= 4 && has(substr(line, index(line, w[4])), "main") && !has(substr(line, index(line, w[4])), comp)) {
					print $0 " " comp; next
				}
			}
			/^URIs:/ { debian = ($0 ~ /debian\.org|debian\.net/) }
			/^$/ { debian = 0 }
			/^Components:/ && debian {
				if (has(substr($0, 13), "main") && !has(substr($0, 13), comp)) { print $0 " " comp; next }
			}
			{ print }
		' "$f" >"$tmp"
		if ! cmp -s "$f" "$tmp"; then
			if [[ "$DRY_RUN" == "1" ]]; then
				echo "+ enable $comp in $f"
			else
				backup "$f"
				cat "$tmp" >"$f"
			fi
			changed=1
		fi
		rm -f "$tmp"
	done
	if [[ "$changed" == "1" && "$DRY_RUN" != "1" ]]; then
		PKG_INDEX_FRESH=0
	fi
	return 0
}

# selinux_port <type> <port> - lets a confined daemon use a non-default
# TCP port (semanage port). Idempotent: a port already carrying the type
# is left alone; -a fails when policy already defines the port with
# another type, then -m remaps it. Not fatal: a missing type (no policy
# module for that daemon) only prints a warning.
selinux_port() {
	local type="$1" port="$2"
	selinux_active || return 0
	if ! command -v semanage >/dev/null 2>&1; then
		[[ "$OS_FAMILY" == "dnf" ]] && pkg_install policycoreutils-python-utils
	fi
	if ! command -v semanage >/dev/null 2>&1; then
		echo "selinux: semanage not found, port $port did not get the type $type" >&2
		return 0
	fi
	if semanage port -l 2>/dev/null | awk -v t="$type" '$1 == t && $2 == "tcp" {$1 = ""; $2 = ""; gsub(/,/, " "); print}' | grep -qw -- "$port"; then
		return 0
	fi
	run semanage port -a -t "$type" -p tcp "$port" ||
		run semanage port -m -t "$type" -p tcp "$port" ||
		echo "selinux: could not give port $port the type $type (the policy may have no such type)" >&2
	return 0
}

# selinux_relabel_installed - one pass over everything dpistack writes,
# at the end of install and reconfigure.
selinux_relabel_installed() {
	selinux_restore \
		"$(path_etc)" "$(path_state_dir)" "$(path_log_dir)" \
		"$(path_sbin_dir)" "$(path_lib_dir)" "$(path_panel_bin)" \
		"$(path_panel_service_unit)" "$(path_watch_service_unit)" "$(path_watch_timer_unit)" \
		"$(path_sudoers)" \
		"${DPISTACK_ROOT}/etc/suricata" "${DPISTACK_ROOT}/var/lib/suricata" \
		"${DPISTACK_ROOT}/var/log/suricata" "${DPISTACK_ROOT}/usr/lib/suricata" \
		"${DPISTACK_ROOT}/etc/ntopng" "${DPISTACK_ROOT}/etc/evebox" "$(path_evebox_data_dir)" \
		"${DPISTACK_ROOT}/etc/nginx/conf.d"
}

# copr_chroot - the COPR chroot dnf would pick for this system
# (epel-N for the RHEL family, fedora-N for Fedora), empty when unknown.
copr_chroot() {
	local major="${OS_VERSION_ID%%.*}"
	[[ "$major" =~ ^[0-9]+$ ]] || return 0
	case "$OS_ID" in
	fedora) echo "fedora-$major" ;;
	*) echo "epel-$major" ;;
	esac
}
