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
	esac
	echo "unknown"
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

	if [[ "$OS_FAMILY" == "unknown" ]]; then
		die 3 "unsupported distribution: id=$OS_ID id_like=$OS_ID_LIKE"
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

pkg_repo_add() {
	# pkg_repo_add <name>
	# Only "oisf" exists as a named repo so far (tech.md 4.3
	# SURICATA_SOURCE=oisf); more get added as their slice needs one.
	local name="$1"
	case "$OS_FAMILY:$name" in
	apt:oisf)
		run add-apt-repository -y ppa:oisf/suricata-stable
		run apt-get update
		;;
	*)
		die 3 "pkg_repo_add: неизвестная комбинация family=$OS_FAMILY repo=$name"
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
	esac
}

# pkg_installed_version <package> - the installed version, empty (and rc 1)
# when the package is not installed.
pkg_installed_version() {
	local out
	case "$OS_FAMILY" in
	apt) out=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null) || return 1 ;;
	dnf) out=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null) || return 1 ;;
	*) return 1 ;;
	esac
	printf '%s' "$out"
}

# pkg_upgrade <package...> - upgrade only what is already installed.
pkg_upgrade() {
	case "$OS_FAMILY" in
	apt) run apt-get install --only-upgrade -y "$@" ;;
	dnf) run dnf upgrade -y "$@" ;;
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
	*)
		echo "$OS_ID: включите EPEL и репозиторий -devel (CodeReady Builder) вручную, установщик их не трогает" >&2
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
		die 3 "pkg_build_deps: неизвестная семья пакетов: $OS_FAMILY"
		;;
	esac
}

# Suricata from git needs Rust 1.85. Ubuntu ships 1.75 as rustc but also
# rustc-1.85 and newer next to it; OISF documents RUSTC/CARGO for ./configure
# to pick them. On a distro with nothing newer configure prints its own
# message and the step stops there.
SURICATA_RUST_MIN_MINOR=85

# pkg_rust_versioned_minor - the smallest N >= 85 for which the apt
# repositories carry rustc-1.N; empty when there is none.
pkg_rust_versioned_minor() {
	apt-cache pkgnames rustc-1. 2>/dev/null | sed -n 's/^rustc-1\.\([0-9][0-9]*\)$/\1/p' |
		awk -v m="$SURICATA_RUST_MIN_MINOR" '$1 >= m' | sort -n | head -n 1
}

# pkg_rust_obtainable - a Rust new enough for Suricata from git is
# installed or can be installed from the repositories.
pkg_rust_obtainable() {
	local have
	have=$(rustc --version 2>/dev/null | sed -n 's/^rustc 1\.\([0-9][0-9]*\)\..*/\1/p')
	((${have:-0} >= SURICATA_RUST_MIN_MINOR)) && return 0
	case "$OS_FAMILY" in
	apt) [[ -n "$(pkg_rust_versioned_minor)" ]] ;;
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
	wanted=$(pkg_rust_versioned_minor)
	if [[ -z "$wanted" ]]; then
		echo "suricata: rustc 1.${have:-?} старше 1.${SURICATA_RUST_MIN_MINOR}, более новых пакетов rustc-1.N в репозиториях нет; сборка может упасть на configure (тогда SURICATA_SOURCE=oisf или distro)" >&2
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
