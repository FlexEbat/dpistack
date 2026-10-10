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
		log "INFO" "dnf versionlock stub called for $1 (dnf family not reachable past preflight yet)"
		;;
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
# source builds. A minimal image has none of them.
pkg_install_base() {
	case "$OS_FAMILY" in
	apt)
		local -a pkgs=(ca-certificates curl wget gnupg jq git openssl logrotate)
		# add-apt-repository (OISF PPA, universe) comes from this package.
		[[ "$OS_ID" == "ubuntu" ]] && pkgs+=(software-properties-common)
		pkg_install "${pkgs[@]}"
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
	*)
		die 3 "pkg_build_deps: сборка из исходников для family=$OS_FAMILY пока не поддерживается"
		;;
	esac
}

# Suricata from git needs Rust 1.85. Ubuntu ships 1.75 as rustc but also
# rustc-1.85 and newer next to it; OISF documents RUSTC/CARGO for ./configure
# to pick them. On a distro with nothing newer configure prints its own
# message and the step stops there.
SURICATA_RUST_MIN_MINOR=85
pkg_select_rust() {
	[[ "$DRY_RUN" == "1" ]] && return 0
	local have wanted
	have=$(rustc --version 2>/dev/null | sed -n 's/^rustc 1\.\([0-9][0-9]*\)\..*/\1/p')
	((${have:-0} >= SURICATA_RUST_MIN_MINOR)) && return 0
	wanted=$(apt-cache pkgnames rustc-1. 2>/dev/null | sed -n 's/^rustc-1\.\([0-9][0-9]*\)$/\1/p' |
		awk -v m="$SURICATA_RUST_MIN_MINOR" '$1 >= m' | sort -n | head -n 1)
	if [[ -z "$wanted" ]]; then
		echo "suricata: rustc 1.${have:-?} старше 1.${SURICATA_RUST_MIN_MINOR}, более новых пакетов rustc-1.N в репозиториях нет; сборка может упасть на configure (тогда SURICATA_SOURCE=oisf или distro)" >&2
		return 0
	fi
	pkg_install "rustc-1.$wanted" "cargo-1.$wanted" || return 1
	export RUSTC="rustc-1.$wanted" CARGO="cargo-1.$wanted"
}
