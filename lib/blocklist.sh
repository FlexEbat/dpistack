#!/usr/bin/env bash
# Block and allow lists of hosts (task 58). An entry is two lines in
# local.rules, in Suricata's own syntax, so nothing is rendered and the CLI
# and the dashboard, which both call `dpistack ips block|allow`, cannot differ:
#
#   # dpistack-block: added=2026-11-22 expires=never by=root note=scanner
#   drop ip 198.51.100.7 any <> any any (msg:"dpistack block 198.51.100.7"; sid:9100001; rev:1;)
#
# `block` writes a drop rule, `allow` a pass rule (Suricata applies pass
# before drop, so an allowed address is never blocked by a block of a whole
# network). The sids come from 9100000-9199999. In IDS mode a drop rule only
# alerts, which `ips block add` says. A line that is not one of these is kept
# as it is. Sourced by install.sh; it defines functions only.

BL_SID_FIRST=9100000
BL_SID_LAST=9199999

# The fields of the entry last read by bl_each.
BL_KIND="" BL_ADDR="" BL_SID="" BL_ADDED="" BL_EXPIRES="" BL_BY="" BL_NOTE=""

# bl_safe_addr <addr[/prefix]> - refuses what would cut the host off from
# itself or from everything: loopback, the unspecified address and a prefix
# so short that it names a large part of the internet.
bl_safe_addr() {
	local addr="$1" prefix=""
	[[ "$addr" == */* ]] && {
		prefix="${addr#*/}"
		addr="${addr%%/*}"
	}
	case "$addr" in
	127.* | ::1 | 0.0.0.0 | ::)
		echo "$1: a loopback or unspecified address is never blocked"
		return 1
		;;
	esac
	if [[ "$addr" == *:* ]]; then
		[[ -z "$prefix" ]] || ((10#$prefix >= 16)) || {
			echo "$1: a prefix shorter than /16 names too much (IPv6)"
			return 1
		}
	else
		[[ -z "$prefix" ]] || ((10#$prefix >= 8)) || {
			echo "$1: a prefix shorter than /8 names too much (IPv4)"
			return 1
		}
	fi
	return 0
}

# bl_each <kind|all> - reads local.rules on stdin, calls bl_visit for each
# entry with BL_* set, passes every other line through bl_other.
# Output goes through the two callbacks.
bl_each() {
	local want="$1" line pending="" k=""
	local meta_re='^# dpistack-(block|allow): added=([^ ]+) expires=([^ ]+) by=([^ ]+)( note=(.*))?$'
	local rule_re='^(drop|pass) ip ([^ ]+) any <> any any \(msg:"[^"]*"; sid:([0-9]+); rev:1;\)$'
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ -n "$pending" ]]; then
			if [[ "$line" =~ $rule_re ]]; then
				BL_KIND="$k"
				BL_ADDR="${BASH_REMATCH[2]}"
				BL_SID="${BASH_REMATCH[3]}"
				if [[ "$want" == all || "$want" == "$k" ]]; then
					bl_visit "$pending" "$line"
				else
					bl_other "$pending"
					bl_other "$line"
				fi
				pending=""
				continue
			fi
			bl_other "$pending"
			pending=""
		fi
		if [[ "$line" =~ $meta_re ]]; then
			k="${BASH_REMATCH[1]}"
			BL_ADDED="${BASH_REMATCH[2]}"
			BL_EXPIRES="${BASH_REMATCH[3]}"
			BL_BY="${BASH_REMATCH[4]}"
			BL_NOTE="${BASH_REMATCH[6]:-}"
			pending="$line"
			continue
		fi
		bl_other "$line"
	done
	[[ -z "$pending" ]] || bl_other "$pending"
	return 0
}

bl_expired() { [[ "$BL_EXPIRES" != never && "$BL_EXPIRES" < "$(exc_today)" ]]; }

bl_next_sid() {
	local used="$1" sid
	for ((sid = BL_SID_FIRST; sid <= BL_SID_LAST; sid++)); do
		[[ " $used " == *" $sid "* ]] || {
			echo "$sid"
			return 0
		}
	done
	return 1
}

bl_stage() {
	local staging
	staging=$(path_staging_dir)
	mkdir -p "$staging"
	chmod 0700 "$staging"
	echo "$staging/local.rules"
}

# bl_commit <staged> - suricata -T on the candidate, then the file, then
# the same apply as any change of local.rules (rules-update).
bl_commit() {
	local staged="$1" out rc
	out=$(suricata_check_set local.rules "$staged" 2>&1)
	rc=$?
	if ((rc != 0)); then
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out" >&2
		((rc == 4)) && fail 4 "ips: Suricata is not installed, nothing was written"
		fail 3 "ips: local.rules does not pass suricata -T, file unchanged"
	fi
	config_commit local.rules "$staged"
	rm -f "$staged"
	apply_config local.rules
}

# bl_list <block|allow> [--json]
bl_list() {
	local kind="$1" json=0 path
	[[ "${2:-}" == "--json" ]] && json=1
	path=$(path_suricata_local_rules)
	local -a rows=()
	bl_visit() {
		local exp="$BL_EXPIRES"
		bl_expired && exp="$BL_EXPIRES (expired)"
		rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$BL_ADDR" "$BL_SID" "$BL_ADDED" "$exp" "$BL_BY" "$BL_NOTE")")
	}
	bl_other() { :; }
	[[ -f "$path" ]] && bl_each "$kind" <"$path"
	if ((json)); then
		printf '%s\n' "${rows[@]}" | jq -Rn '[inputs | select(length > 0) | split("\t") | {address: .[0], sid: (.[1] | tonumber), added: .[2], expires: .[3], by: .[4], note: .[5]}]'
	elif ((${#rows[@]} == 0)); then
		echo "the $kind list is empty"
	else
		printf '%s\n' "${rows[@]}" | awk -F'\t' '{printf "%-40s sid %s  added %s  expires %s  by %s  %s\n", $1, $2, $3, $4, $5, $6}'
	fi
}

# bl_add <block|allow> <addr> [--days N | --never] [--note T] [--by NAME]
bl_add() {
	local kind="$1" addr="${2:-}" days="" note="" by="${SUDO_USER:-root}" path staged used="" sid exp msg action
	[[ -n "$addr" ]] || fail 2 "ips $kind add: an address is needed"
	shift 2
	while (($#)); do
		case "$1" in
		--days | --note | --by)
			(($# >= 2)) || fail 2 "ips $kind add: $1 needs a value"
			case "$1" in
			--days) days="$2" ;;
			--note) note="$2" ;;
			--by) by="$2" ;;
			esac
			shift 2
			;;
		--never)
			days=""
			shift
			;;
		*) fail 2 "ips $kind add: unknown option: $1" ;;
		esac
	done
	exc_valid_ip "$addr" || fail 5 "ips $kind add: not an IP address or network: $addr"
	msg=$(bl_safe_addr "$addr") || fail 5 "ips $kind add: $msg"
	[[ "$note" =~ $EXC_NOTE_RE ]] || fail 5 "ips $kind add: the note is up to 80 characters of letters, digits and . _ : / @ + , = -"
	[[ "$by" =~ $EXC_BY_RE ]] || fail 5 "ips $kind add: the name is not valid"
	exp=never
	if [[ -n "$days" ]]; then
		exc_in_range "$days" 1 "$EXC_DAYS_MAX" || fail 5 "ips $kind add: --days is 1 to $EXC_DAYS_MAX"
		exp=$(date -u -d "+$days days" +%Y-%m-%d)
	fi
	path=$(path_suricata_local_rules)
	staged=$(bl_stage)
	mkdir -p "$(dirname "$path")"
	[[ -f "$path" ]] || : >"$path"
	ctl_lock
	bl_visit() {
		used+=" $BL_SID"
		# the same address again replaces the old entry (a new expiry, a new note)
		if [[ "$BL_KIND" != "$kind" || "$BL_ADDR" != "$addr" ]]; then
			bl_other "$1"
			bl_other "$2"
		fi
	}
	bl_other() { printf '%s\n' "$1" >>"$staged"; }
	: >"$staged"
	bl_each all <"$path"
	# every sid in use, kept or not, so a new one never repeats an old one
	used+=" $(grep -Eo 'sid:[0-9]+' "$path" | cut -d: -f2 | tr '\n' ' ')"
	sid=$(bl_next_sid "$used") || {
		ctl_unlock
		rm -f "$staged"
		fail 3 "ips $kind add: no free sid left in $BL_SID_FIRST-$BL_SID_LAST"
	}
	ctl_unlock
	action=drop
	[[ "$kind" == allow ]] && action=pass
	{
		printf '# dpistack-%s: added=%s expires=%s by=%s' "$kind" "$(exc_today)" "$exp" "$by"
		[[ -n "$note" ]] && printf ' note=%s' "$note"
		printf '\n%s ip %s any <> any any (msg:"dpistack %s %s"; sid:%s; rev:1;)\n' "$action" "$addr" "$kind" "$addr" "$sid"
	} >>"$staged"
	bl_commit "$staged"
	audit_append "$by" "cli ips" "$kind add" ok "$addr sid $sid (exit 0)"
	echo "$kind: $addr (sid $sid, expires $exp)"
	if [[ "$kind" == block && "$(conf_get SURICATA_MODE ids)" != "ips" ]]; then
		echo "note: Suricata is in IDS mode, so this drop rule only alerts; switch with: dpistack mode ips"
	fi
}

# bl_remove <block|allow> <addr|sid>
bl_remove() {
	local kind="$1" what="${2:-}" path staged removed=0 by="${SUDO_USER:-root}"
	[[ -n "$what" ]] || fail 2 "ips $kind remove: an address or a sid is needed"
	path=$(path_suricata_local_rules)
	[[ -f "$path" ]] || fail 5 "ips $kind remove: no such entry: $what"
	staged=$(bl_stage)
	: >"$staged"
	ctl_lock
	bl_visit() {
		if [[ "$BL_KIND" == "$kind" && ("$BL_ADDR" == "$what" || "$BL_SID" == "$what") ]]; then
			removed=$((removed + 1))
		else
			bl_other "$1"
			bl_other "$2"
		fi
	}
	bl_other() { printf '%s\n' "$1" >>"$staged"; }
	bl_each all <"$path"
	ctl_unlock
	if ((removed == 0)); then
		rm -f "$staged"
		fail 5 "ips $kind remove: no such entry: $what"
	fi
	bl_commit "$staged"
	audit_append "$by" "cli ips" "$kind remove" ok "$what (exit 0)"
	echo "removed from the $kind list: $what"
}

# bl_prune <block|allow> - drops the entries of that list past their last
# day. Prints what it did.
bl_prune() {
	local kind="$1" path staged dropped=0
	path=$(path_suricata_local_rules)
	[[ -f "$path" ]] || return 0
	staged=$(bl_stage)
	: >"$staged"
	ctl_lock
	bl_visit() {
		if [[ "$BL_KIND" == "$kind" ]] && bl_expired; then
			dropped=$((dropped + 1))
		else
			bl_other "$1"
			bl_other "$2"
		fi
	}
	bl_other() { printf '%s\n' "$1" >>"$staged"; }
	bl_each all <"$path"
	ctl_unlock
	if ((dropped == 0)); then
		rm -f "$staged"
		echo "nothing expired"
		return 0
	fi
	bl_commit "$staged"
	audit_append "${SUDO_USER:-root}" "cli ips" prune ok "removed $dropped expired (exit 0)"
	echo "removed $dropped expired"
}

# cmd_ips_list <block|allow> <sub> [args...]
cmd_ips_list() {
	local kind="$1" sub="${2:-}"
	shift
	[[ $# -eq 0 ]] || shift
	case "$sub" in
	list) bl_list "$kind" "$@" ;;
	add) bl_add "$kind" "$@" ;;
	remove) bl_remove "$kind" "$@" ;;
	prune) bl_prune "$kind" ;;
	*) fail 2 "ips $kind: list [--json] | add <addr[/prefix]> [--days N|--never] [--note T] [--by NAME] | remove <addr|sid> | prune" ;;
	esac
}
