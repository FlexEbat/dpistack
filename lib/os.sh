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
