#!/usr/bin/env bash
# The security check of the panel (tech.md 18.45): `dpistack security check
# [--json]`. It reads the settings, the modes of a few files and the audit log,
# changes nothing, and answers with a list, each item with a level (ok, warn,
# crit or na) and a hint for the fix. The panel shows the same list. Sourced by
# install.sh; it defines functions only.

SECURITY_STALE_DAYS=90

security_val() { conf_get "$1" "${SCHEMA_DEFAULT[$1]:-}"; }

# security_row <id> <level> <title> <detail> <fix> - one JSON object.
security_row() {
	jq -nc --arg id "$1" --arg level "$2" --arg title "$3" --arg detail "$4" --arg fix "$5" \
		'{id: $id, level: $level, title: $title, detail: $detail, fix: $fix}'
}

# security_mode <path> - the permission bits as octal, empty when not there.
security_mode() { stat -c %a "$1" 2>/dev/null; }

security_check_access() {
	local mode
	mode=$(security_val ACCESS_MODE)
	case "$mode" in
	localhost) security_row access-mode ok "Who can reach the panel" "Only this machine: the panel and the components listen on 127.0.0.1." "" ;;
	lan) security_row access-mode warn "Who can reach the panel" "The panel is open to the local network ($(security_val LAN_CIDR))." "dpistack settings set ACCESS_MODE=localhost, or ACCESS_MODE=nginx with NGINX_TLS set" ;;
	nginx) security_row access-mode ok "Who can reach the panel" "Through nginx, which is where the access rules and the TLS are." "" ;;
	*) security_row access-mode warn "Who can reach the panel" "ACCESS_MODE is $mode, which this check does not know." "dpistack settings set ACCESS_MODE=localhost" ;;
	esac
}

security_check_tls() {
	local mode tls
	mode=$(security_val ACCESS_MODE)
	tls=$(security_val NGINX_TLS)
	if [[ "$mode" == localhost ]]; then
		security_row tls ok "Encryption of the panel connection" "Nothing crosses a network, so there is nothing to encrypt." ""
	elif [[ "$mode" == nginx && "$tls" != none ]]; then
		security_row tls ok "Encryption of the panel connection" "nginx serves the panel over TLS ($tls)." ""
	elif [[ "$mode" == nginx ]]; then
		security_row tls warn "Encryption of the panel connection" "nginx serves plain HTTP: passwords and sessions cross the network in clear." "dpistack settings set NGINX_TLS=selfsigned (or existing, with NGINX_CERT and NGINX_KEY)"
	else
		security_row tls warn "Encryption of the panel connection" "The panel speaks plain HTTP to the local network: passwords and sessions cross it in clear." "dpistack settings set ACCESS_MODE=nginx NGINX_TLS=selfsigned"
	fi
}

# The ports that are still the ones in the manual, for a component that is on.
security_check_ports() {
	local mode key def val hits=""
	mode=$(security_val ACCESS_MODE)
	if [[ "$mode" == localhost ]]; then
		security_row default-ports ok "Ports left at their defaults" "Closed to the network anyway: everything listens on 127.0.0.1." ""
		return 0
	fi
	for key in "${SCHEMA_KEYS[@]}"; do
		[[ "$key" == *_PORT ]] || continue
		schema_depends_ok "$key" security_val || continue
		def="${SCHEMA_DEFAULT[$key]}"
		val=$(security_val "$key")
		[[ -n "$def" && "$val" == "$def" ]] && hits+="$key=$val "
	done
	if [[ -z "$hits" ]]; then
		security_row default-ports ok "Ports left at their defaults" "Every port of a component that is on has been changed." ""
	else
		security_row default-ports warn "Ports left at their defaults" "Open to the network on the port of the manual: ${hits% }." "dpistack settings set PANEL_PORT=<another port> (the same for each key named)"
	fi
}

# Accounts that have not signed in for a long time, from the audit log.
security_check_users() {
	local users audit now cutoff stale n
	users=$(users_load | jq -c '[.users[]? | select((.disabled // false) | not) | {name, created: (.created // "")}]')
	if [[ "$users" == "[]" ]]; then
		security_row stale-users na "Accounts that do not sign in" "There are no accounts." ""
		return 0
	fi
	audit=$(path_audit_jsonl)
	if [[ ! -r "$audit" ]]; then
		security_row stale-users na "Accounts that do not sign in" "There is no audit log yet, so the last sign in of an account is not known." ""
		return 0
	fi
	now=$(alerts_now)
	cutoff=$(alerts_iso $((now - SECURITY_STALE_DAYS * 86400)))
	stale=$(cat "$audit" "$audit".[1-9] 2>/dev/null |
		jq -cR 'fromjson? | select(.action == "POST /api/login" and .result == "ok") | {user, ts}' 2>/dev/null |
		jq -sc --argjson users "$users" --arg cutoff "$cutoff" '
			(group_by(.user) | map({key: .[0].user, value: (map(.ts) | max)}) | from_entries) as $last
			| [$users[] | . as $u | ($last[$u.name] // $u.created // "") as $seen
				| select($seen == "" or $seen[0:19] < $cutoff[0:19]) | $u.name]')
	n=$(jq 'length' <<<"$stale")
	if ((n == 0)); then
		security_row stale-users ok "Accounts that do not sign in" "Every account signed in within $SECURITY_STALE_DAYS days, or is newer than that." ""
	else
		security_row stale-users warn "Accounts that do not sign in" "No sign in for $SECURITY_STALE_DAYS days: $(jq -r 'join(", ")' <<<"$stale")." "dpistack users disable <name>, or dpistack users remove <name>"
	fi
}

# Who may change the rules: a world writable file is a way to turn them off.
security_check_rules() {
	local f mode owner bad="" seen=0
	for f in "$(path_suricata_ruleset)" "$(path_suricata_local_rules)" "$(dirname "$(path_suricata_local_rules)")"; do
		[[ -e "$f" ]] || continue
		seen=1
		mode=$(security_mode "$f")
		owner=$(stat -c %U "$f" 2>/dev/null)
		if ((8#$mode & 8#002)); then
			bad+="$f is writable by everyone ($mode); "
		elif [[ "$owner" != root ]]; then
			bad+="$f belongs to $owner, not root; "
		fi
	done
	if ((seen == 0)); then
		security_row rules-files na "Permissions of the rule files" "There are no rule files yet." ""
	elif [[ -z "$bad" ]]; then
		security_row rules-files ok "Permissions of the rule files" "The rules and their directory belong to root and nobody else may write them." ""
	else
		security_row rules-files crit "Permissions of the rule files" "${bad% }" "chown root: <path> and chmod o-w <path> for each file named"
	fi
}

# The files that hold secrets or hashes must not be open to every account.
security_check_secrets() {
	local f mode bad=""
	for f in "$(path_secrets)" "$(path_users)" "$(path_api_tokens)"; do
		[[ -e "$f" ]] || continue
		mode=$(security_mode "$f")
		((8#$mode & 8#007)) && bad+="$f is open to everyone ($mode); "
	done
	if [[ -z "$bad" ]]; then
		security_row secret-files ok "Files with secrets and hashes" "secrets.conf, users.json and api-tokens.json cannot be read by other accounts." ""
	else
		security_row secret-files crit "Files with secrets and hashes" "${bad% }" "chmod o-rwx <path> for each file named"
	fi
}

# security_check [--json]
security_check() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "security check: only --json is accepted" ;;
	esac
	command -v jq >/dev/null 2>&1 || fail 1 "security: jq is needed"
	local rows doc
	rows=$({
		security_check_access
		security_check_tls
		security_check_ports
		security_check_users
		security_check_rules
		security_check_secrets
	} | jq -sc .)
	doc=$(jq -nc --arg ts "$(alerts_iso "$(alerts_now)")" --argjson c "$rows" \
		'{ts: $ts, checks: $c, counts: {ok: ($c | map(select(.level == "ok")) | length), warn: ($c | map(select(.level == "warn")) | length),
			crit: ($c | map(select(.level == "crit")) | length), na: ($c | map(select(.level == "na")) | length)}}')
	if ((json)); then
		printf '%s\n' "$doc"
		return 0
	fi
	jq -r '(.checks[] | "[\(.level)] \(.id): \(.detail)" + (if .fix != "" then "  fix: \(.fix)" else "" end)),
		"\(.counts.ok) ok, \(.counts.warn) warnings, \(.counts.crit) critical, \(.counts.na) not applicable"' <<<"$doc"
}

# cmd_security check
cmd_security() {
	local sub="${1:-}"
	[[ $# -ge 1 ]] && shift
	case "$sub" in
	check) security_check "$@" ;;
	*) fail 2 "security: check [--json]" ;;
	esac
}
