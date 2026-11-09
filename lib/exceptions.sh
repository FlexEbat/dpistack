#!/usr/bin/env bash
# Exceptions (tech.md 18.40): what Suricata should not alert on, or should
# alert on less often. The entries live in Suricata's own file,
# threshold.config, in Suricata's own syntax, so nothing is rendered and
# nothing can differ between the CLI and the dashboard: both call the verb
# `dpistack exceptions`, which is the only writer. dpistack keeps its data
# (when, by whom, until when, why) in one comment line before each entry:
#
#   # dpistack: added=2026-11-08 expires=2026-12-08 by=admin note=printer scans
#   suppress gen_id 1, sig_id 2001219, track by_src, ip 10.0.0.5
#
# Kinds: `suppress` (a rule is silent, for one address or, with no address,
# for everyone) and `limit` (at most COUNT alerts per SECONDS for each
# address). `expires=never` is allowed: an entry then stays until removed.
# A line that is not one of these (written by hand or in the config editor)
# is kept as it is and is listed as kind "other"; no verb removes it.
# Sourced by install.sh; it defines functions only.

EXC_SID_RE='^[0-9]{1,10}$'
EXC_NOTE_RE='^[A-Za-z0-9 ._:/@+,=-]{0,80}$'
EXC_BY_RE='^[A-Za-z0-9][A-Za-z0-9._@-]{0,31}$'
EXC_DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
EXC_DAYS_MAX=3650
EXC_COUNT_MAX=1000000
EXC_SECONDS_MAX=86400

# The fields of the entry last read by exc_parse_line / exc_parse_meta.
E_ID="" E_KIND="" E_SID="" E_TRACK="" E_IP="" E_COUNT="" E_SECONDS=""
E_ADDED="" E_EXPIRES="" E_BY="" E_NOTE=""

exc_today() { date -u +%Y-%m-%d; }

# exc_in_range <value> <min> <max> - a plain number within the bounds.
exc_in_range() {
	[[ "$1" =~ ^[0-9]{1,9}$ ]] || return 1
	((10#$1 >= $2 && 10#$1 <= $3))
}

# exc_header - what a new threshold.config starts with (the installer writes
# it too, so Suricata always finds the file it is told to read).
exc_header() {
	cat <<'HEADER'
# Exceptions of Suricata (threshold.config), managed with: dpistack exceptions
# Entries are written by dpistack; a line you add by hand is kept as it is.
HEADER
}

# exc_valid_ip <addr[/prefix]> - address syntax only; `suricata -T` has the
# last word before anything is written.
exc_valid_ip() {
	local addr="$1" prefix="" o
	[[ "$addr" == */* ]] && {
		prefix="${addr#*/}"
		addr="${addr%%/*}"
		[[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
	}
	if [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
		local IFS=.
		for o in $addr; do ((10#$o <= 255)) || return 1; done
		[[ -z "$prefix" ]] || ((10#$prefix <= 32)) || return 1
		return 0
	fi
	if [[ "$addr" == *:* && "$addr" =~ ^[0-9A-Fa-f:.]+$ && "$addr" != *:::* && "$addr" != *::*::* ]]; then
		[[ -z "$prefix" ]] || ((10#$prefix <= 128)) || return 1
		return 0
	fi
	return 1
}

# exc_parse_line <line> - sets E_KIND E_SID E_TRACK E_IP E_COUNT E_SECONDS
# and E_ID; returns 1 when the line is not an entry dpistack understands.
exc_parse_line() {
	local line="$1"
	E_KIND="" E_SID="" E_TRACK="any" E_IP="any" E_COUNT="" E_SECONDS="" E_ID=""
	if [[ "$line" =~ ^suppress\ gen_id\ 1,\ sig_id\ ([0-9]+)$ ]]; then
		E_KIND=suppress E_SID="${BASH_REMATCH[1]}"
	elif [[ "$line" =~ ^suppress\ gen_id\ 1,\ sig_id\ ([0-9]+),\ track\ by_(src|dst),\ ip\ ([0-9A-Fa-f.:/]+)$ ]]; then
		E_KIND=suppress E_SID="${BASH_REMATCH[1]}" E_TRACK="${BASH_REMATCH[2]}" E_IP="${BASH_REMATCH[3]}"
	elif [[ "$line" =~ ^threshold\ gen_id\ 1,\ sig_id\ ([0-9]+),\ type\ limit,\ track\ by_(src|dst),\ count\ ([0-9]+),\ seconds\ ([0-9]+)$ ]]; then
		E_KIND=limit E_SID="${BASH_REMATCH[1]}" E_TRACK="${BASH_REMATCH[2]}" E_COUNT="${BASH_REMATCH[3]}" E_SECONDS="${BASH_REMATCH[4]}"
	else
		return 1
	fi
	E_ID="${E_KIND}:${E_SID}:${E_TRACK}:${E_IP}"
}

# exc_parse_meta <comment line> - sets E_ADDED E_EXPIRES E_BY E_NOTE. A
# missing or damaged comment means "no data", and an entry with no expiry
# data never expires: it is not dpistack's to drop.
exc_parse_meta() {
	local meta="$1" rest
	E_ADDED="" E_EXPIRES="never" E_BY="" E_NOTE=""
	[[ "$meta" == "# dpistack: "* ]] || return 0
	rest="${meta#\# dpistack: }"
	[[ "$rest" =~ added=([0-9-]+) ]] && E_ADDED="${BASH_REMATCH[1]}"
	[[ "$rest" =~ expires=([0-9a-z-]+) ]] && E_EXPIRES="${BASH_REMATCH[1]}"
	[[ "$rest" =~ by=([A-Za-z0-9._@-]+) ]] && E_BY="${BASH_REMATCH[1]}"
	[[ "$rest" == *" note="* ]] && E_NOTE="${rest#* note=}"
	[[ "$E_EXPIRES" == never || "$E_EXPIRES" =~ $EXC_DATE_RE ]] || E_EXPIRES="never"
	return 0
}

# exc_expired - is the entry last parsed past its last day?
exc_expired() {
	[[ "$E_EXPIRES" != never && "$E_EXPIRES" < "$(exc_today)" ]]
}

# exc_days_left - whole days left, or "never"; 0 on the last day.
exc_days_left() {
	local end now
	[[ "$E_EXPIRES" == never ]] && {
		echo never
		return
	}
	end=$(date -u -d "$E_EXPIRES" +%s 2>/dev/null) || {
		echo never
		return
	}
	now=$(date -u -d "$(exc_today)" +%s)
	echo $(((end - now) / 86400))
}

# exc_default_days - EXCEPTIONS_DEFAULT_DAYS from dpistack.conf, read in a
# subshell so that the settings the calling verb loaded stay as they are.
exc_default_days() {
	(
		config_reset
		config_load_defaults
		[[ -r "$(path_conf)" ]] && config_load_kv_file "$(path_conf)"
		echo "${CONF[EXCEPTIONS_DEFAULT_DAYS]:-30}"
	)
}

# exc_stream <mode> [<id>] - the file on stdin, the new file on stdout.
# Modes: copy, remove <id>, prune. EXC_DROPPED counts the entries left out.
# Read it from a file and write it to a file (no pipe), or the counter is
# lost with the subshell.
exc_stream() {
	local mode="$1" id="${2:-}" line meta="" drop
	EXC_DROPPED=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "# dpistack: "* ]]; then
			[[ -n "$meta" ]] && printf '%s\n' "$meta"
			meta="$line"
			continue
		fi
		if exc_parse_line "$line"; then
			exc_parse_meta "$meta"
			drop=0
			case "$mode" in
			remove) [[ "$E_ID" == "$id" ]] && drop=1 ;;
			prune) exc_expired && drop=1 ;;
			esac
			if ((drop)); then
				EXC_DROPPED=$((EXC_DROPPED + 1))
			else
				[[ -n "$meta" ]] && printf '%s\n' "$meta"
				printf '%s\n' "$line"
			fi
			meta=""
			continue
		fi
		[[ -n "$meta" ]] && printf '%s\n' "$meta"
		meta=""
		printf '%s\n' "$line"
	done
	[[ -n "$meta" ]] && printf '%s\n' "$meta"
	return 0
}

# exc_each <callback> - calls the callback once per line of the file, with
# E_* set; kind "other" for a line that is no entry (comments and blank
# lines are skipped).
exc_each() {
	local cb="$1" path line meta="" n=0
	path=$(path_suricata_threshold)
	[[ -f "$path" ]] || return 0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "# dpistack: "* ]]; then
			meta="$line"
			continue
		fi
		if [[ -z "$line" || "$line" == \#* ]]; then
			continue
		fi
		n=$((n + 1))
		if exc_parse_line "$line"; then
			exc_parse_meta "$meta"
		else
			E_KIND=other E_SID="" E_TRACK="" E_IP="" E_COUNT="" E_SECONDS="" E_ID="other:$n"
			E_ADDED="" E_EXPIRES="never" E_BY="" E_NOTE="$line"
		fi
		meta=""
		"$cb"
	done <"$path"
}

exc_print_text() {
	local left
	left=$(exc_days_left)
	if [[ "$E_KIND" == other ]]; then
		printf '%s\t(not managed)\t%s\n' "$E_ID" "$E_NOTE"
		return
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$E_ID" "$E_KIND" "$E_SID" "$E_EXPIRES" "$left" "${E_BY:--}" "${E_NOTE:--}"
}

exc_print_json() {
	local first_flag="${EXC_FIRST:-1}" left expired=false
	left=$(exc_days_left)
	exc_expired && expired=true
	((first_flag)) || printf ','
	EXC_FIRST=0
	printf '{"id":"%s","kind":"%s","sid":%s,"track":"%s","ip":"%s","count":%s,"seconds":%s,"added":"%s","expires":"%s","days_left":%s,"expired":%s,"by":"%s","note":"%s"}' \
		"$E_ID" "$E_KIND" "${E_SID:-0}" "$E_TRACK" "$E_IP" "${E_COUNT:-0}" "${E_SECONDS:-0}" "$E_ADDED" "$E_EXPIRES" \
		"$([[ "$left" == never ]] && echo null || echo "$left")" "$expired" "$(json_escape "$E_BY")" "$(json_escape "$E_NOTE")"
}

exc_list() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "exceptions list: only --json is accepted" ;;
	esac
	if ((json)); then
		printf '{"default_days":%s,"today":"%s","entries":[' "$(exc_default_days)" "$(exc_today)"
		EXC_FIRST=1
		exc_each exc_print_json
		printf ']}\n'
	else
		exc_each exc_print_text
	fi
}

# exc_commit <staged> - checks the file with `suricata -T`, replaces the live
# one (with a backup) and reloads Suricata when it runs. A file that does
# not check is never written.
exc_commit() {
	local staged="$1" out rc
	out=$(suricata_check_set threshold.config "$staged" 2>&1)
	rc=$?
	if ((rc != 0)); then
		rm -f "$staged"
		[[ -n "$out" ]] && echo "$out" >&2
		((rc == 4)) && fail 4 "exceptions: Suricata is not installed, nothing was written"
		fail 3 "exceptions: threshold.config does not pass suricata -T, file unchanged"
	fi
	[[ -f "$(path_suricata_threshold)" ]] || exc_header >"$(path_suricata_threshold)"
	config_commit threshold.config "$staged"
	rm -f "$staged"
	exc_reload
}

# exc_reload - makes a running Suricata read the file. Native: only when its
# command socket exists (it does not when Suricata is stopped); in a
# container the reload is tried and a failure is reported.
exc_reload() {
	if [[ "$(component_unit suricata 2>/dev/null)" != docker:* ]] && [[ ! -S "$(path_suricata_socket)" ]]; then
		return 0
	fi
	suricata_reload_now >/dev/null 2>&1 ||
		fail 1 "exceptions: saved, but Suricata did not reload; run: dpistack reload suricata"
}

exc_stage() {
	local staging
	staging=$(path_staging_dir)
	mkdir -p "$staging"
	chmod 0700 "$staging"
	echo "$staging/threshold.config"
}

# exc_add <suppress|limit> <sid> [options] - see the usage text.
exc_add() {
	local kind="${1:-}" sid="${2:-}" track="" ip="" count="" seconds="" days="" never=0 note="" by=""
	[[ "$kind" == suppress || "$kind" == limit ]] || fail 2 "exceptions add: suppress|limit <sid> [options]"
	[[ "$sid" =~ $EXC_SID_RE ]] || fail 5 "exceptions add: the sid must be a number"
	shift 2
	while (($#)); do
		case "$1" in
		--track | --ip | --count | --seconds | --days | --note | --by)
			(($# >= 2)) || fail 2 "exceptions add: $1 needs a value"
			case "$1" in
			--track) track="$2" ;;
			--ip) ip="$2" ;;
			--count) count="$2" ;;
			--seconds) seconds="$2" ;;
			--days) days="$2" ;;
			--note) note="$2" ;;
			--by) by="$2" ;;
			esac
			shift 2
			;;
		--never)
			never=1
			shift
			;;
		*) fail 2 "exceptions add: unknown option: $1" ;;
		esac
	done

	[[ -z "$track" || "$track" == src || "$track" == dst ]] || fail 5 "exceptions add: --track is src or dst"
	[[ -z "$note" || "$note" =~ $EXC_NOTE_RE ]] || fail 5 "exceptions add: the note is up to 80 characters of letters, digits and . : / @ + , = - and spaces"
	[[ -z "$by" ]] && by="${SUDO_USER:-${USER:-root}}"
	[[ "$by" =~ $EXC_BY_RE ]] || by=unknown
	if [[ -n "$days" ]]; then
		((never == 0)) || fail 2 "exceptions add: --days and --never exclude each other"
		exc_in_range "$days" 1 "$EXC_DAYS_MAX" || fail 5 "exceptions add: --days is 1 to $EXC_DAYS_MAX"
	fi

	local line
	case "$kind" in
	suppress)
		[[ -z "$count" && -z "$seconds" ]] || fail 2 "exceptions add suppress: --count and --seconds belong to limit"
		if [[ -n "$ip" ]]; then
			[[ -n "$track" ]] || fail 2 "exceptions add suppress: --ip needs --track src|dst"
			exc_valid_ip "$ip" || fail 5 "exceptions add: not an IP address or network: $ip"
			line="suppress gen_id 1, sig_id $((10#$sid)), track by_$track, ip $ip"
		else
			[[ -z "$track" ]] || fail 2 "exceptions add suppress: --track needs --ip"
			line="suppress gen_id 1, sig_id $((10#$sid))"
			echo "warning: no --ip, so rule $((10#$sid)) is silent for every address" >&2
		fi
		;;
	limit)
		[[ -z "$ip" ]] || fail 2 "exceptions add limit: it counts per address, --ip does not apply"
		[[ -n "$track" ]] || fail 2 "exceptions add limit: --track src|dst is needed"
		exc_in_range "$count" 1 "$EXC_COUNT_MAX" || fail 5 "exceptions add limit: --count is 1 to $EXC_COUNT_MAX"
		exc_in_range "$seconds" 1 "$EXC_SECONDS_MAX" || fail 5 "exceptions add limit: --seconds is 1 to $EXC_SECONDS_MAX"
		line="threshold gen_id 1, sig_id $((10#$sid)), type limit, track by_$track, count $((10#$count)), seconds $((10#$seconds))"
		;;
	esac

	local expires
	if ((never)); then
		expires=never
	else
		[[ -n "$days" ]] || days=$(exc_default_days)
		if [[ "$days" == 0 ]]; then
			expires=never
		else
			expires=$(date -u -d "+$((10#$days)) days" +%Y-%m-%d)
		fi
	fi

	exc_parse_line "$line" || fail 1 "exceptions add: internal error, the line does not parse"
	local new_id="$E_ID" path staged
	path=$(path_suricata_threshold)
	exc_id_exists "$new_id" && fail 1 "exceptions add: $new_id already exists; remove it first"

	ctl_lock
	staged=$(exc_stage)
	if [[ -f "$path" ]]; then
		exc_stream copy <"$path" >"$staged"
	else
		: >"$staged"
	fi
	[[ ! -s "$staged" || "$(tail -c1 "$staged")" == "" ]] || printf '\n' >>"$staged"
	printf '# dpistack: added=%s expires=%s by=%s%s\n%s\n' \
		"$(exc_today)" "$expires" "$by" "${note:+ note=$note}" "$line" >>"$staged"
	ctl_unlock
	exc_commit "$staged"
	echo "$new_id"
}

exc_id_exists() {
	EXC_FOUND_ID="$1"
	EXC_FOUND=0
	exc_each exc_match_id
	((EXC_FOUND))
}

exc_match_id() {
	[[ "$E_ID" == "$EXC_FOUND_ID" ]] && EXC_FOUND=1
	return 0
}

exc_remove() {
	local id="${1:-}" path staged
	[[ $# -eq 1 && "$id" =~ ^(suppress|limit):[0-9]+:(any|src|dst):[0-9A-Fa-f.:/]+$ ]] ||
		fail 5 "exceptions remove: an id like suppress:2001219:src:10.0.0.5 is needed (see: exceptions list)"
	path=$(path_suricata_threshold)
	exc_id_exists "$id" || fail 4 "exceptions remove: no such entry: $id"
	ctl_lock
	staged=$(exc_stage)
	exc_stream remove "$id" <"$path" >"$staged"
	ctl_unlock
	exc_commit "$staged"
	echo "removed $id"
}

# exc_prune - drops the entries past their last day. The watchdog runs it;
# it is safe to run by hand and does nothing when nothing is due.
exc_prune() {
	local path staged dropped
	path=$(path_suricata_threshold)
	[[ -f "$path" ]] || return 0
	ctl_lock
	staged=$(exc_stage)
	exc_stream prune <"$path" >"$staged"
	dropped=$EXC_DROPPED
	ctl_unlock
	if ((dropped == 0)); then
		rm -f "$staged"
		echo "nothing expired"
		return 0
	fi
	exc_commit "$staged"
	audit_append "${SUDO_USER:-root}" "cli exceptions" prune ok "removed $dropped expired (exit 0)"
	echo "removed $dropped expired"
}

cmd_exceptions() {
	[[ $# -ge 1 ]] || fail 2 "exceptions: list|add|remove|prune"
	local sub="$1"
	shift
	case "$sub" in
	list) exc_list "$@" ;;
	add) exc_add "$@" ;;
	remove) exc_remove "$@" ;;
	prune)
		[[ $# -eq 0 ]] || fail 2 "exceptions prune: no arguments"
		exc_prune
		;;
	*) fail 2 "exceptions: unknown subcommand: $sub" ;;
	esac
}
