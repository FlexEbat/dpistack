#!/usr/bin/env bash
# Migrations: what an upgrade to a new version does by itself (tech.md 18.57).
#
# Three things change between releases and none of them may be left to the
# person who upgrades:
#   1. a source build whose recipe changed (a new configure flag) is built
#      again: every build records its recipe number in the state file
#      (build.<part>.recipe) and the step check refuses a build of an older
#      recipe, so the normal install rebuilds it;
#   2. a saved setting whose meaning changed is resolved here, in memory,
#      before the config is validated and written (migrate_<version>);
#   3. everything rendered (unit files, suricata.yaml, the panel) is rendered
#      again by the ordinary steps, because their checks compare hashes.
# The version that last finished an install is kept as install.version. A host
# that has no such line but has a finished install is treated as older than
# every migration, so each one runs; a migration is safe to run twice.

# The recipe numbers and build_recipe_have are in lib/state.sh: the build steps
# read them and some of them are loaded without this file.

MIGRATION_VERSIONS=(0.50.0 0.51.0)
declare -A MIGRATION_TEXT=(
	["0.50.0"]="EVE_MAX_SIZE_MB gets its default of 100 when it was saved empty; a saved EVE_REDIS value is a live Redis output from now on; a Suricata built from source is rebuilt with Redis support"
	["0.51.0"]="the Redis output is a bounded stream (EVE_REDIS_MAXLEN) instead of a list: the old list of events that nobody read is deleted, because a stream cannot be added to a key that holds a list"
)

# version_lt <a> <b> - 0 when version a is lower than version b.
version_lt() {
	[[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# migrate_from_version - the version of the last finished install, 0.0.0 for a
# finished install that did not record it, empty on a host without install.
migrate_from_version() {
	local v
	v=$(state_read_value install.version)
	if [[ -n "$v" ]]; then
		echo "$v"
	elif state_install_finished; then
		echo "0.0.0"
	fi
}

# migrate_pending - the versions of the migrations that an upgrade runs.
migrate_pending() {
	local from v
	from=$(migrate_from_version)
	[[ -n "$from" ]] || return 0
	for v in "${MIGRATION_VERSIONS[@]}"; do
		version_lt "$from" "$v" || continue
		version_lt "$DPISTACK_VERSION" "$v" && continue
		echo "$v"
	done
}

# migrate_conf <key> <default> - a setting from the layered config of this run,
# or from the saved file when the run has not loaded it (the verbs).
migrate_conf() {
	local v=""
	if declare -p CONF >/dev/null 2>&1; then
		v="${CONF[$1]:-}"
	fi
	[[ -n "$v" ]] || v=$(conf_get "$1" "$2" 2>/dev/null || true)
	echo "${v:-$2}"
}

# migrate_rebuilds - one line for each source build that has to be made again,
# "part have want reason". nDPI comes first: Suricata links its plugin.
migrate_rebuilds() {
	local have
	if [[ "$(migrate_conf NDPI_ENABLE no)" == yes && "$(migrate_conf NDPI_SOURCE source)" == source &&
	-n "$(state_read_value "$(ndpi_built_ref_state_key 2>/dev/null)" 2>/dev/null)" ]]; then
		have=$(build_recipe_have ndpi)
		[[ "$have" != "$NDPI_BUILD_RECIPE" ]] && echo "ndpi $have $NDPI_BUILD_RECIPE the build recipe of nDPI changed"
	fi
	if [[ "$(migrate_conf SURICATA_ENABLE yes)" == yes && "$(migrate_conf SURICATA_SOURCE distro)" == source &&
	-n "$(state_read_value "${SURICATA_BUILT_REF_STATE_KEY:-}")" ]]; then
		have=$(build_recipe_have suricata)
		[[ "$have" != "$SURICATA_BUILD_RECIPE" ]] && echo "suricata $have $SURICATA_BUILD_RECIPE Redis support (hiredis) is added to the build"
	fi
	return 0
}

migrate_0_50_0() {
	if [[ -z "${CONF[EVE_MAX_SIZE_MB]:-}" ]]; then
		CONF[EVE_MAX_SIZE_MB]=100
		echo "migrate 0.50.0: EVE_MAX_SIZE_MB was saved empty, it is 100 now (used only with EVE_ROTATE=size)"
	fi
	case "${CONF[EVE_REDIS]:-}" in
	"" | no | No | NO | off | none | false) ;;
	*) echo "migrate 0.50.0: EVE_REDIS=${CONF[EVE_REDIS]} was ignored before and is a live Redis output now; set EVE_REDIS=no to keep eve.json only" ;;
	esac
	return 0
}

migrate_0_51_0() {
	local target host port key type
	target=$(suricata_redis_target 2>/dev/null) || return 0
	read -r host port key <<<"$target"
	echo "migrate 0.51.0: the Redis output of EVE_REDIS=${CONF[EVE_REDIS]} is a stream trimmed to about ${CONF[EVE_REDIS_MAXLEN]:-100000} events now, not a list"
	if ! command -v redis-cli >/dev/null 2>&1; then
		echo "migrate 0.51.0: redis-cli is not installed; if $key on $host:$port holds a list from 0.50.0, delete it: redis-cli -h $host -p $port del $key"
		return 0
	fi
	type=$(redis-cli -h "$host" -p "$port" type "$key" 2>/dev/null || true)
	[[ "$type" == "list" ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "migrate 0.51.0: would delete the list $key on $host:$port (events that nobody read)"
	elif redis-cli -h "$host" -p "$port" del "$key" >/dev/null 2>&1; then
		echo "migrate 0.51.0: deleted the list $key on $host:$port (events that nobody read): a stream cannot be added to a key that holds a list"
	else
		echo "migrate 0.51.0: could not delete the list $key on $host:$port; delete it by hand: redis-cli -h $host -p $port del $key"
	fi
	return 0
}

# migrate_plan - what an upgrade from the recorded version does, as text.
migrate_plan() {
	local from v part have want why n=0
	from=$(migrate_from_version)
	if [[ -z "$from" ]]; then
		echo "no finished install on this host: nothing to migrate"
		return 0
	fi
	echo "installed: ${from/0.0.0/an older version that did not record it}, this version: $DPISTACK_VERSION"
	for v in $(migrate_pending); do
		echo "migration $v: ${MIGRATION_TEXT[$v]}"
		n=$((n + 1))
	done
	while read -r part have want why; do
		[[ -n "$part" ]] || continue
		echo "rebuild $part: recipe $have -> $want, $why"
		n=$((n + 1))
	done < <(migrate_rebuilds)
	((n)) || echo "nothing to migrate"
	return 0
}

# migrate_needed - 0 when an upgrade left work on this host: a migration of a
# version above the recorded one, or a source build of an older recipe.
migrate_needed() {
	[[ -n "$(migrate_pending)$(migrate_rebuilds)" ]]
}

# migrate_notice - one line on stderr when work is pending, for the commands a
# person runs to look at the host. It does not change anything: the install,
# `dpistack update` and `dpistack migrate` do the work.
migrate_notice() {
	migrate_needed || return 0
	echo "dpistack: this host still has work from an earlier version (details: dpistack migrate --plan); it is done by: sudo dpistack migrate" >&2
}

# migrate_run - called by the install right after the config is layered and
# before it is validated and written: the migrations edit CONF, so the file
# that is written is already the migrated one. A fresh host runs none.
migrate_run() {
	local from v part have want why
	from=$(migrate_from_version)
	[[ -n "$from" ]] || return 0
	for v in $(migrate_pending); do
		"migrate_${v//./_}"
	done
	while read -r part have want why; do
		[[ -n "$part" ]] || continue
		echo "migrate: $part is built again (recipe $have -> $want: $why)"
	done < <(migrate_rebuilds)
	migrate_backup
	return 0
}

# migrate_backup - a rebuild replaces a program that works, so the config and
# the state are copied first (`dpistack backup`, the same archive). A backup
# that fails is said and the upgrade goes on: it is a copy of files, not a way
# back for the binary. Nothing is made in a dry run or when nothing is rebuilt.
migrate_backup() {
	[[ -n "$(migrate_rebuilds)" && "${DRY_RUN:-0}" != "1" ]] || return 0
	declare -F backup_create >/dev/null || return 0
	echo "migrate: a backup is made before the rebuild"
	if ! (backup_create); then
		echo "migrate: the backup failed; the upgrade goes on"
	fi
	return 0
}

# migrate_record - the install ran to its end: this version is the installed one.
migrate_record() {
	state_write_value install.version "$DPISTACK_VERSION"
}
