#!/usr/bin/env bash
# Settings profiles (tech.md 18.44): a profile is a name for a set of
# KEY=VALUE pairs of dpistack.conf, saved in /var/lib/dpistack/profiles.json
# and applied later through the same path as `settings set`, so a profile gets
# the same checks, the same light or heavy weight and the same confirmation of
# a wider access as any change. Secrets are never part of a profile. The file
# has one writer, `dpistack settings profile` as root, under a lock and
# replaced atomically. Sourced by install.sh; it defines functions only.
#
#   {"version":1,"profiles":{"lan-watch":{"created":"...","by":"admin",
#    "keys":{"ACCESS_MODE":"lan","WATCH_INTERVAL_SEC":"30"}}}}

PROFILE_NAME_RE='^[a-z0-9][a-z0-9_-]{0,31}$'
PROFILE_BY_RE='^[A-Za-z0-9][A-Za-z0-9._@-]{0,31}$'
PROFILE_MAX=50
PROFILE_MAX_KEYS=100

profiles_read() {
	local f
	f=$(path_profiles_json)
	if [[ -r "$f" ]] && jq -e 'type == "object" and (.profiles | type == "object")' "$f" >/dev/null 2>&1; then
		cat "$f"
	else
		echo '{"version":1,"profiles":{}}'
	fi
}

# profile_name_check <verb> <name> - the name is a short lowercase word.
profile_name_check() {
	[[ -n "${2:-}" ]] || fail 2 "settings profile $1: a profile name is needed"
	[[ "$2" =~ $PROFILE_NAME_RE ]] || fail 5 "settings profile $1: the name is 1 to 32 characters: lowercase letters, digits, - and _, starting with a letter or digit"
}

# profile_write <json> - under the lock the caller holds.
profile_write() {
	local dir tmp
	dir=$(path_state_dir)
	tmp=$(mktemp "$dir/profiles.XXXXXX") || fail 1 "settings profile: cannot write in $dir"
	printf '%s\n' "$1" >"$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$(path_profiles_json)"
}

# profile_lock - takes the lock on fd 9 of the caller's shell.
profile_lock() {
	local dir
	dir=$(path_state_dir)
	mkdir -p "$dir" || fail 1 "settings profile: cannot create $dir"
	command -v flock >/dev/null 2>&1 || fail 1 "settings profile: flock is needed"
	exec {PROFILE_LOCK_FD}>"$dir/profiles.lock" || fail 1 "settings profile: cannot open the lock"
	flock -x "$PROFILE_LOCK_FD"
}

profile_unlock() { exec {PROFILE_LOCK_FD}>&-; }

# settings_profile_list [--json]
settings_profile_list() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "settings profile list: only --json is accepted" ;;
	esac
	command -v jq >/dev/null 2>&1 || fail 1 "settings profile: jq is needed"
	local doc
	doc=$(profiles_read | jq -c '{profiles: (.profiles | to_entries | sort_by(.key)
		| map({name: .key, created: .value.created, by: .value.by, count: (.value.keys | length)}))}')
	if ((json)); then
		printf '%s\n' "$doc"
		return 0
	fi
	jq -r '(.profiles[] | "\(.name)\t\(.count) keys\t\(.created) by \(.by)"), (if (.profiles | length) == 0 then "no profiles" else empty end)' <<<"$doc"
}

# settings_profile_show <name> [--json]
settings_profile_show() {
	local name="${1:-}" json=0
	profile_name_check show "$name"
	shift
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "settings profile show: only --json is accepted" ;;
	esac
	command -v jq >/dev/null 2>&1 || fail 1 "settings profile: jq is needed"
	local one
	one=$(profiles_read | jq -c --arg n "$name" '.profiles[$n] // null')
	[[ "$one" != null ]] || fail 5 "settings profile show: no such profile: $name"
	if ((json)); then
		jq -c --arg n "$name" '{name: $n} + .' <<<"$one"
		return 0
	fi
	jq -r '.keys | to_entries[] | "\(.key)=\(.value)"' <<<"$one"
}

# profile_pairs <name> - the pairs of a profile, one KEY=VALUE per line.
profile_pairs() {
	profiles_read | jq -r --arg n "$1" '.profiles[$n].keys // empty | to_entries[] | "\(.key)=\(.value)"'
}

# settings_profile_save <name> [--by NAME] [KEY=VALUE...] - pairs from the
# arguments or, with none, from stdin (a value may hold characters that the
# argument check of a verb refuses). A profile that the checks of `settings
# check` refuse is not saved. Saving a name again replaces that profile.
settings_profile_save() {
	local name="${1:-}" by="${SUDO_USER:-root}" arg
	profile_name_check save "$name"
	shift
	local -a rest=()
	while (($#)); do
		case "$1" in
		--by)
			[[ $# -ge 2 ]] || fail 2 "settings profile save: --by needs a value"
			by="$2"
			shift 2
			;;
		*)
			rest+=("$1")
			shift
			;;
		esac
	done
	[[ "$by" =~ $PROFILE_BY_RE ]] || fail 5 "settings profile save: --by is a user name"
	command -v jq >/dev/null 2>&1 || fail 1 "settings profile: jq is needed"
	settings_collect_pairs "${rest[@]}"
	local -a pairs=("${SETTINGS_PAIRS[@]}")
	((${#pairs[@]} >= 1)) || fail 2 "settings profile save: at least one KEY=VALUE is needed"
	((${#pairs[@]} <= PROFILE_MAX_KEYS)) || fail 5 "settings profile save: at most $PROFILE_MAX_KEYS keys"
	local key seen=" "
	for arg in "${pairs[@]}"; do
		[[ "$arg" == *=* ]] || fail 5 "settings profile save: not KEY=VALUE: $arg"
		key="${arg%%=*}"
		schema_known "$key" || fail 5 "settings profile save: unknown key: $key"
		schema_is_secret "$key" && fail 5 "settings profile save: $key is a secret and never goes into a profile"
		[[ "$seen" == *" $key "* ]] && fail 5 "settings profile save: $key is given twice"
		seen+="$key "
	done
	# The same checks as `settings check`, against the config as it is now.
	local out rc=0
	out=$(settings_check "${pairs[@]}" 2>&1) || rc=$?
	if ((rc != 0)); then
		[[ -n "$out" ]] && printf '%s\n' "$out" >&2
		fail "$([[ $rc -eq 5 ]] && echo 5 || echo 3)" "settings profile save: the values are refused, nothing saved"
	fi
	local keys='{}' pair
	for pair in "${pairs[@]}"; do
		keys=$(jq -c --arg k "${pair%%=*}" --arg v "${pair#*=}" '. + {($k): $v}' <<<"$keys")
	done
	profile_lock
	local doc new
	doc=$(profiles_read)
	if [[ "$(jq -r --arg n "$name" '.profiles | has($n)' <<<"$doc")" != true ]] &&
		(($(jq '.profiles | length' <<<"$doc") >= PROFILE_MAX)); then
		profile_unlock
		fail 5 "settings profile save: at most $PROFILE_MAX profiles; delete one first"
	fi
	new=$(jq -c --arg n "$name" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg by "$by" --argjson keys "$keys" \
		'.profiles[$n] = {created: $at, by: $by, keys: $keys} | .version = 1' <<<"$doc")
	profile_write "$new"
	profile_unlock
	log INFO "settings profile $name saved by $by (${#pairs[@]} keys)"
}

# settings_profile_delete <name> [--by NAME]
settings_profile_delete() {
	local name="${1:-}" by="${SUDO_USER:-root}"
	profile_name_check delete "$name"
	shift
	if [[ "${1:-}" == --by ]]; then
		[[ $# -ge 2 ]] || fail 2 "settings profile delete: --by needs a value"
		by="$2"
		shift 2
	fi
	[[ $# -eq 0 ]] || fail 2 "settings profile delete: unknown argument: $1"
	[[ "$by" =~ $PROFILE_BY_RE ]] || fail 5 "settings profile delete: --by is a user name"
	command -v jq >/dev/null 2>&1 || fail 1 "settings profile: jq is needed"
	profile_lock
	local doc
	doc=$(profiles_read)
	if [[ "$(jq -r --arg n "$name" '.profiles | has($n)' <<<"$doc")" != true ]]; then
		profile_unlock
		fail 5 "settings profile delete: no such profile: $name"
	fi
	profile_write "$(jq -c --arg n "$name" 'del(.profiles[$n])' <<<"$doc")"
	profile_unlock
	log INFO "settings profile $name deleted by $by"
}

# settings_profile_apply <name> [--apply|--apply-heavy] [--confirm-access]
# sets the keys of the profile as `settings set` would, with the same flags.
settings_profile_apply() {
	local name="${1:-}"
	profile_name_check apply "$name"
	shift
	command -v jq >/dev/null 2>&1 || fail 1 "settings profile: jq is needed"
	local -a pairs=() flags=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && pairs+=("$line")
	done < <(profile_pairs "$name")
	((${#pairs[@]} >= 1)) || fail 5 "settings profile apply: no such profile: $name"
	while (($#)); do
		case "$1" in
		--apply | --apply-heavy | --confirm-access) flags+=("$1") ;;
		*) fail 2 "settings profile apply: unknown argument: $1" ;;
		esac
		shift
	done
	settings_set "${flags[@]}" "${pairs[@]}"
}

# settings_profile list|show|save|delete|apply
settings_profile() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	list) settings_profile_list "$@" ;;
	show) settings_profile_show "$@" ;;
	save) settings_profile_save "$@" ;;
	delete) settings_profile_delete "$@" ;;
	apply) settings_profile_apply "$@" ;;
	*) fail 2 "settings profile: list [--json] | show NAME [--json] | save NAME [KEY=VALUE...] | delete NAME | apply NAME [--apply|--apply-heavy] [--confirm-access]" ;;
	esac
}
