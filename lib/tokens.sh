#!/usr/bin/env bash
# API tokens (tech.md 18.45): `dpistack tokens create|list|revoke`. A token
# lets a script call the panel API as `Authorization: Bearer dpt_...`. The
# secret is printed once, by `create`; /etc/dpistack/api-tokens.json (0640,
# root:dpistack, beside users.json) keeps only its SHA-256, so a copy of the
# file does not let anyone in. The panel reads the file and never writes it;
# this verb is its one writer, under a lock, replaced atomically. Sourced by
# install.sh; it defines functions only.
#
#   {"tokens":[{"id":"1a2b3c4d","name":"ci","user":"admin","scope":"read",
#    "hash":"<sha256 hex>","created":"...","expires":"..."}]}

TOKEN_NAME_RE='^[a-z0-9][a-z0-9 ._-]{0,31}$'
TOKEN_SCOPES=(read viewer analyst operator admin)
TOKEN_DAYS_DEFAULT=90
TOKEN_DAYS_MAX=365
TOKEN_PER_USER=10
TOKEN_MAX=100

tokens_read() {
	local f
	f=$(path_api_tokens)
	if [[ -r "$f" ]] && jq -e 'type == "object" and (.tokens | type == "array")' "$f" >/dev/null 2>&1; then
		cat "$f"
	else
		echo '{"tokens":[]}'
	fi
}

# tokens_store - writes the file from stdin: 0640, root:dpistack.
tokens_store() {
	atomic_write "$(path_api_tokens)" 0640 || return 1
	if getent group dpistack >/dev/null 2>&1; then
		chown root:dpistack "$(path_api_tokens)" || return 1
	fi
}

# tokens_user_perms <name> - the permissions of an account as a JSON array;
# nothing and a failure when the account is not there or is disabled.
tokens_user_perms() {
	users_load | jq -ce --arg n "$1" --argjson presets "$(users_presets)" '
		(.users[] | select(.name == $n and ((.disabled // false) | not))) as $u
		| if $u.role == "custom" then ($u.perms // []) else ($presets[$u.role] // []) end' 2>/dev/null
}

# tokens_scope_perms <scope> <owner perms JSON> - what the token would hold:
# the owner's permissions for `read`, else the role's that the owner also has.
tokens_scope_ok() {
	local scope="$1" owner="$2"
	[[ "$scope" == read ]] && return 0
	jq -ne --arg s "$scope" --argjson owner "$owner" --argjson presets "$(users_presets)" \
		'($presets[$s] // []) as $p | ($p | length) > 0 and ($p | all(. as $x | $owner | index($x) != null))' >/dev/null
}

tokens_lock() {
	local dir
	dir=$(path_etc)
	mkdir -p "$dir" || fail 1 "tokens: cannot create $dir"
	command -v flock >/dev/null 2>&1 || fail 1 "tokens: flock is needed"
	exec {TOKENS_LOCK_FD}>"$dir/.api-tokens.lock" || fail 1 "tokens: cannot open the lock"
	flock -x "$TOKENS_LOCK_FD"
}

tokens_unlock() { exec {TOKENS_LOCK_FD}>&-; }

# tokens_create --user U --name N [--scope S] [--days D] [--json]
tokens_create() {
	local user="" name="" scope=read days="$TOKEN_DAYS_DEFAULT" json=0
	while (($#)); do
		case "$1" in
		--user | --name | --scope | --days)
			[[ $# -ge 2 ]] || fail 2 "tokens create: $1 needs a value"
			case "$1" in
			--user) user="$2" ;;
			--name) name="$2" ;;
			--scope) scope="$2" ;;
			--days) days="$2" ;;
			esac
			shift 2
			;;
		--json)
			json=1
			shift
			;;
		*) fail 2 "tokens create: unknown argument: $1" ;;
		esac
	done
	[[ -n "$user" ]] || fail 2 "tokens create: --user is needed"
	[[ -n "$name" ]] || fail 2 "tokens create: --name is needed"
	command -v jq >/dev/null 2>&1 || fail 1 "tokens: jq is needed"
	users_check_name "$user"
	[[ "$name" =~ $TOKEN_NAME_RE ]] || fail 5 "tokens create: the name is 1 to 32 characters: lowercase letters, digits, space and . _ -, starting with a letter or digit"
	in_list "$scope" "${TOKEN_SCOPES[@]}" || fail 5 "tokens create: the scope is one of: ${TOKEN_SCOPES[*]}"
	if ! [[ "$days" =~ ^[0-9]{1,3}$ ]]; then
		fail 5 "tokens create: --days is 1 to $TOKEN_DAYS_MAX"
	fi
	days=$((10#$days)) # 08 is eight days, not an octal error
	if ((days < 1 || days > TOKEN_DAYS_MAX)); then
		fail 5 "tokens create: --days is 1 to $TOKEN_DAYS_MAX"
	fi
	local owner
	owner=$(tokens_user_perms "$user") || fail 5 "tokens create: no such user, or the user is disabled: $user"
	tokens_scope_ok "$scope" "$owner" || fail 5 "tokens create: the scope $scope holds more than $user may do"

	local secret id hash now exp epoch
	secret="dpt_$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
	id=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
	hash=$(printf '%s' "$secret" | sha256sum | cut -d' ' -f1)
	epoch=$(alerts_now)
	now=$(alerts_iso "$epoch")
	exp=$(alerts_iso $((epoch + days * 86400)))

	tokens_lock
	local doc
	doc=$(tokens_read)
	if (($(jq '.tokens | length' <<<"$doc") >= TOKEN_MAX)); then
		tokens_unlock
		fail 5 "tokens create: at most $TOKEN_MAX tokens; revoke one first"
	fi
	if (($(jq --arg u "$user" '[.tokens[] | select(.user == $u)] | length' <<<"$doc") >= TOKEN_PER_USER)); then
		tokens_unlock
		fail 5 "tokens create: $user has $TOKEN_PER_USER tokens already; revoke one first"
	fi
	jq -c --arg id "$id" --arg name "$name" --arg user "$user" --arg scope "$scope" --arg hash "$hash" --arg now "$now" --arg exp "$exp" \
		'.tokens += [{id: $id, name: $name, user: $user, scope: $scope, hash: $hash, created: $now, expires: $exp}]' <<<"$doc" | tokens_store ||
		{
			tokens_unlock
			fail 1 "tokens create: cannot write $(path_api_tokens)"
		}
	tokens_unlock
	log INFO "api token $id ($name) made for $user, scope $scope, $days days"
	# The secret goes to stdout and nowhere else: not to the log, not to the audit.
	if ((json)); then
		jq -nc --arg id "$id" --arg token "$secret" --arg exp "$exp" '{id: $id, token: $token, expires: $exp}'
	else
		printf 'id: %s\ntoken: %s\nexpires: %s\nThe token is shown once; only its hash is kept.\n' "$id" "$secret" "$exp"
	fi
}

# tokens_list [--user U] [--json] - never the hash.
tokens_list() {
	local user="" json=0
	while (($#)); do
		case "$1" in
		--user)
			[[ $# -ge 2 ]] || fail 2 "tokens list: --user needs a value"
			user="$2"
			shift 2
			;;
		--json)
			json=1
			shift
			;;
		*) fail 2 "tokens list: unknown argument: $1" ;;
		esac
	done
	command -v jq >/dev/null 2>&1 || fail 1 "tokens: jq is needed"
	[[ -z "$user" ]] || users_check_name "$user"
	local now doc
	now=$(alerts_iso "$(alerts_now)")
	doc=$(tokens_read | jq -c --arg u "$user" --arg now "$now" '{tokens: ([.tokens[] | select($u == "" or .user == $u)
		| {id, name, user, scope, created, expires, expired: (.expires[0:19] <= $now[0:19])}] | sort_by(.created) | reverse)}')
	if ((json)); then
		printf '%s\n' "$doc"
		return 0
	fi
	jq -r '(.tokens[] | "\(.id)\t\(.name)\t\(.user)\t\(.scope)\texpires \(.expires)" + (if .expired then " (expired)" else "" end)), (if (.tokens | length) == 0 then "no tokens" else empty end)' <<<"$doc"
}

# tokens_revoke <id> [--user U] - with --user the token must be that user's.
tokens_revoke() {
	local id="${1:-}" user=""
	[[ -n "$id" ]] || fail 2 "tokens revoke: a token id is needed"
	[[ "$id" =~ ^[0-9a-f]{8}$ ]] || fail 5 "tokens revoke: an id is 8 hex digits"
	shift
	if [[ "${1:-}" == --user ]]; then
		[[ $# -ge 2 ]] || fail 2 "tokens revoke: --user needs a value"
		user="$2"
		shift 2
		users_check_name "$user"
	fi
	[[ $# -eq 0 ]] || fail 2 "tokens revoke: unknown argument: $1"
	command -v jq >/dev/null 2>&1 || fail 1 "tokens: jq is needed"
	tokens_lock
	local doc
	doc=$(tokens_read)
	if [[ "$(jq -r --arg id "$id" --arg u "$user" '[.tokens[] | select(.id == $id and ($u == "" or .user == $u))] | length' <<<"$doc")" == 0 ]]; then
		tokens_unlock
		fail 5 "tokens revoke: no such token: $id"
	fi
	jq -c --arg id "$id" '.tokens |= map(select(.id != $id))' <<<"$doc" | tokens_store || {
		tokens_unlock
		fail 1 "tokens revoke: cannot write $(path_api_tokens)"
	}
	tokens_unlock
	log INFO "api token $id revoked"
}

# cmd_tokens create|list|revoke
cmd_tokens() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	create) tokens_create "$@" ;;
	list) tokens_list "$@" ;;
	revoke) tokens_revoke "$@" ;;
	*) fail 2 "tokens: create --user U --name N [--scope read|viewer|analyst|operator|admin] [--days D] [--json] | list [--user U] [--json] | revoke ID [--user U]" ;;
	esac
}
