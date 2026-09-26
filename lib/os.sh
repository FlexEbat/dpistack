#!/usr/bin/env bash
# OS detection and package-manager wrappers. Steps call pkg_install,
# never apt-get/dnf directly (tech.md section 3).

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_FAMILY=""

os_release_file() { echo "${DPISTACK_ROOT}/etc/os-release"; }

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
	f=$(os_release_file)
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

pkg_repo_add() {
	# pkg_repo_add <name> <url-or-descriptor>
	# Real repository handling ships with the steps that need one
	# (slice 2 onward); slice 1 only needs the dispatch point to exist.
	log "INFO" "pkg_repo_add stub called for family=$OS_FAMILY name=$1"
}

pkg_pin() {
	# pkg_pin <package> <version>
	case "$OS_FAMILY" in
	apt)
		log "INFO" "pkg_pin (apt-mark hold) stub called for $1=$2"
		;;
	dnf)
		log "INFO" "pkg_pin (dnf versionlock) stub called for $1=$2"
		;;
	esac
}
