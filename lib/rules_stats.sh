#!/usr/bin/env bash
# Rules v2 (tech.md 18.41): what the rule sets hold, when they were updated,
# what a rule says, whether a custom rule is sound, and how a config file
# changed. The verbs only read (`rules-local check` reads what it is given),
# so the CLI and the dashboard show the same numbers: the panel calls these
# verbs and adds nothing of its own. Sourced by install.sh; functions only.
#
# How the numbers are made (checked against suricata-update 1.3.3): the tool
# keeps every source it downloaded in <data dir>/update/cache as
# <md5 of the URL>-<file name of the URL>, and writes the merged set with a
# disabled rule as `# alert ...`. A source is therefore counted from its
# newest cache file, and the state of each of its rules is read from the
# merged set by sid.

RULES_HISTORY_MAX=100
RULES_HISTORY_SHOW=50
RULES_DESCRIBE_MAX=20
RULES_LOCAL_MAX_BYTES=1048576
RULES_LOCAL_SID_MIN=9000000
RULES_LOCAL_SID_MAX=9999999
RULE_ACTIONS='alert|drop|pass|reject|rejectsrc|rejectdst|rejectboth'

path_rules_history() { echo "$(path_state_dir)/rules-updates.jsonl"; }

# rs_iso <file> - the modification time of a file as UTC ISO, or null.
rs_iso() {
	local t
	t=$(stat -c %Y "$1" 2>/dev/null) || {
		echo null
		return
	}
	printf '"%s"' "$(date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ)"
}

# rs_rule_states <file...> - one "sid state" line per rule in the files,
# state 1 for an active rule and 0 for one commented out. The file may be
# the merged set or a custom file; a line that is no rule is ignored.
rs_rule_states() {
	awk -v actions="$RULE_ACTIONS" '
		BEGIN { re = "^[# \t]*(" actions ")[ \t]" }
		$0 ~ re && match($0, /sid: *[0-9]+/) {
			s = substr($0, RSTART, RLENGTH)
			sub(/sid: */, "", s)
			print s, ($0 ~ /^[ \t]*#/) ? 0 : 1
		}' "$@" 2>/dev/null
}

# rs_archive_rules <file> - the rule lines of one cached source: the
# members of a tar.gz, or the file itself when it is not an archive.
rs_archive_rules() {
	if tar -tzf "$1" >/dev/null 2>&1; then
		tar -xzOf "$1" 2>/dev/null
	else
		cat "$1" 2>/dev/null
	fi
}

# rs_enabled_sources - "name<TAB>url" for every enabled source; the url is
# empty unless the source file names one (a custom source).
rs_enabled_sources() {
	local dir f name url
	dir="$(path_rules_data_dir)/update/sources"
	[[ -d "$dir" ]] || return 0
	while IFS= read -r f; do
		name=$(sed -n 's/^source:[ \t]*//p' "$f" | head -n1 | tr -d "\"'\r")
		url=$(sed -n 's/^url:[ \t]*//p' "$f" | head -n1 | tr -d "\"'\r")
		[[ -n "$name" ]] && printf '%s\t%s\n' "$name" "$url"
	done < <(find "$dir" -type f -name '*.yaml' | sort)
}

# rs_index_url <name> - the url of a source in the index suricata-update
# keeps next to the cache, or nothing.
rs_index_url() {
	local idx
	idx="$(path_rules_data_dir)/update/cache/index.yaml"
	[[ -f "$idx" ]] || return 0
	awk -v want="$1" '
		/^  [^ ].*:[ \t]*$/ { name = $0; sub(/^  /, "", name); sub(/:[ \t]*$/, "", name); inside = (name == want); next }
		inside && /^    url:/ { u = $0; sub(/^    url:[ \t]*/, "", u); gsub(/["\047\r]/, "", u); print u; exit }
	' "$idx"
}

# rs_cache_file <url> - the newest cache file of a source, or nothing.
rs_cache_file() {
	local base cache f newest=""
	base="${1##*/}"
	base="${base%%\?*}"
	[[ -n "$base" ]] || return 0
	cache="$(path_rules_data_dir)/update/cache"
	[[ -d "$cache" ]] || return 0
	while IFS= read -r f; do
		[[ "$f" == *.md5 ]] && continue
		if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
	done < <(find "$cache" -maxdepth 1 -type f -name "*-$base" 2>/dev/null)
	[[ -n "$newest" ]] && echo "$newest"
	return 0
}

# rs_count_line <states-file> - "total enabled disabled" of the rules in a
# states stream on stdin ("sid state", one per rule), each sid once.
rs_counts() {
	awk '!seen[$1]++ { t++; if ($2 == 1) e++; else d++ } END { printf "%d %d %d\n", t, e + 0, d + 0 }'
}

# rs_source_counts <cache-file> <merged-states-file> - "total enabled
# disabled missing" for one source: total is the distinct sids in the source,
# enabled and disabled are their state in the merged set, missing are the
# ones the merged set does not hold (a rule that failed to load).
rs_source_counts() {
	rs_archive_rules "$1" | rs_rule_states /dev/stdin | awk -v map="$2" '
		BEGIN { while ((getline line < map) > 0) { split(line, p, " "); st[p[1]] = p[2] } }
		!seen[$1]++ { t++; if (!($1 in st)) m++; else if (st[$1] == 1) e++; else d++ }
		END { printf "%d %d %d %d\n", t + 0, e + 0, d + 0, m + 0 }'
}

# rules_stats [--json] - the counts of the merged set, of local.rules and of
# every enabled source.
rules_stats() {
	local json=0
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "rules-stats: only --json is accepted" ;;
	esac
	local merged local_rules tmp
	merged=$(path_suricata_ruleset)
	local_rules=$(path_suricata_local_rules)
	tmp=$(mktemp)
	local present=false mt=null mtot=0 men=0 mdis=0
	if [[ -f "$merged" ]]; then
		present=true
		mt=$(rs_iso "$merged")
		rs_rule_states "$merged" >"$tmp"
		read -r mtot men mdis < <(rs_counts <"$tmp")
	fi
	local ltot=0 len=0 ldis=0
	if [[ -f "$local_rules" ]]; then
		read -r ltot len ldis < <(rs_rule_states "$local_rules" | rs_counts)
	fi

	local -a rows=()
	local name url file total en dis miss fetched
	while IFS=$'\t' read -r name url; do
		[[ -n "$name" ]] || continue
		[[ -n "$url" ]] || url=$(rs_index_url "$name")
		file=""
		[[ -n "$url" ]] && file=$(rs_cache_file "$url")
		if [[ -n "$file" ]]; then
			read -r total en dis miss < <(rs_source_counts "$file" "$tmp")
			fetched=$(rs_iso "$file")
			rows+=("$name"$'\t'"$total"$'\t'"$en"$'\t'"$dis"$'\t'"$miss"$'\t'"$fetched")
		else
			rows+=("$name"$'\t'"-"$'\t'"-"$'\t'"-"$'\t'"-"$'\t'"null")
		fi
	done < <(rs_enabled_sources)
	rm -f "$tmp"

	if ((json)); then
		printf '{"ruleset":{"present":%s,"updated":%s,"total":%s,"enabled":%s,"disabled":%s},' "$present" "$mt" "$mtot" "$men" "$mdis"
		printf '"local":{"total":%s,"enabled":%s,"disabled":%s},"sources":[' "$ltot" "$len" "$ldis"
		local first=1 r
		for r in "${rows[@]}"; do
			IFS=$'\t' read -r name total en dis miss fetched <<<"$r"
			((first)) || printf ','
			first=0
			if [[ "$total" == "-" ]]; then
				printf '{"name":"%s","cached":false,"total":null,"enabled":null,"disabled":null,"missing":null,"fetched":null}' "$(json_escape "$name")"
			else
				printf '{"name":"%s","cached":true,"total":%s,"enabled":%s,"disabled":%s,"missing":%s,"fetched":%s}' "$(json_escape "$name")" "$total" "$en" "$dis" "$miss" "$fetched"
			fi
		done
		printf ']}\n'
		return 0
	fi
	printf 'ruleset\t%s\t%s\t%s\n' "$mtot" "$men" "$mdis"
	printf 'local\t%s\t%s\t%s\n' "$ltot" "$len" "$ldis"
	local r
	for r in "${rows[@]}"; do
		printf 'source\t%s\n' "$r"
	done
}

# rules_history_record <ok|failed> <log file> - one line per update, from what
# suricata-update said. A number it did not print stays 0 and the line says
# so by `parsed: false`.
rules_history_record() {
	local result="$1" log="$2" line total=0 enabled=0 added=0 removed=0 modified=0 loaded=0 parsed=false
	line=$(grep -E 'Writing rules to .*: total: [0-9]+' "$log" 2>/dev/null | tail -n1)
	if [[ "$line" =~ total:\ ([0-9]+).*enabled:\ ([0-9]+).*added:\ ([0-9]+).*removed\ ([0-9]+).*modified:\ ([0-9]+) ]]; then
		total="${BASH_REMATCH[1]}" enabled="${BASH_REMATCH[2]}" added="${BASH_REMATCH[3]}" removed="${BASH_REMATCH[4]}" modified="${BASH_REMATCH[5]}"
		parsed=true
	fi
	line=$(grep -E 'Loaded [0-9]+ rules' "$log" 2>/dev/null | tail -n1)
	[[ "$line" =~ Loaded\ ([0-9]+)\ rules ]] && loaded="${BASH_REMATCH[1]}"
	local file tmp
	file=$(path_rules_history)
	mkdir -p "$(dirname "$file")"
	tmp=$(mktemp)
	{
		[[ -f "$file" ]] && tail -n $((RULES_HISTORY_MAX - 1)) "$file"
		printf '{"time":"%s","result":"%s","loaded":%s,"total":%s,"enabled":%s,"added":%s,"removed":%s,"modified":%s,"parsed":%s}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$result" "$loaded" "$total" "$enabled" "$added" "$removed" "$modified" "$parsed"
	} >"$tmp"
	cat "$tmp" >"$file"
	rm -f "$tmp"
	chmod 0644 "$file"
}

# rules_history [--json] - the newest updates first.
rules_history() {
	local json=0 file
	case "${1:-}" in
	"") ;;
	--json) json=1 ;;
	*) fail 2 "rules-history: only --json is accepted" ;;
	esac
	file=$(path_rules_history)
	if ((json)); then
		printf '{"updates":['
		if [[ -f "$file" ]]; then
			tail -n "$RULES_HISTORY_SHOW" "$file" | tac | paste -sd, -
		fi
		printf ']}\n'
		return 0
	fi
	[[ -f "$file" ]] || return 0
	tail -n "$RULES_HISTORY_SHOW" "$file" | tac | sed -E 's/[{}"]//g; s/,/ /g'
}

# rules_describe <sid>... - what each rule says, from the merged set and from
# local.rules. A sid that is in neither is reported as not found.
rules_describe() {
	[[ $# -ge 1 && $# -le $RULES_DESCRIBE_MAX ]] || fail 2 "rules-describe: 1 to $RULES_DESCRIBE_MAX sids"
	local sid
	for sid in "$@"; do
		[[ "$sid" =~ ^[0-9]{1,10}$ ]] || fail 5 "rules-describe: a sid is a number"
	done
	local files=() f
	for f in "$(path_suricata_local_rules)" "$(path_suricata_ruleset)"; do
		[[ -f "$f" ]] && files+=("$f")
	done
	local want
	want=$(printf '%s\n' "$@" | sort -u | paste -sd' ' -)
	printf '{"rules":['
	if ((${#files[@]})); then
		awk -v actions="$RULE_ACTIONS" -v want="$want" '
			BEGIN {
				re = "^[# \t]*(" actions ")[ \t]"
				n = split(want, w, " "); for (i = 1; i <= n; i++) wanted[w[i]] = 1
			}
			function unq(s) { gsub(/\\"/, "\"", s); gsub(/\\;/, ";", s); gsub(/\\\\/, "\\", s); return s }
		function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return s }
			FNR == 1 { where = (FILENAME ~ /local\.rules$/) ? "local.rules" : "suricata.rules" }
			$0 ~ re && match($0, /sid: *[0-9]+/) {
				s = substr($0, RSTART, RLENGTH); sub(/sid: */, "", s)
				if (!(s in wanted) || (s in done)) next
				done[s] = 1
				msg = ""
				if (match($0, /msg: *"([^"\\]|\\.)*"/)) { msg = substr($0, RSTART, RLENGTH); sub(/msg: *"/, "", msg); sub(/"$/, "", msg); msg = unq(msg) }
				printf "%s{\"sid\":%s,\"msg\":\"%s\",\"enabled\":%s,\"where\":\"%s\"}", (c++ ? "," : ""), s, esc(msg), ($0 ~ /^[ \t]*#/) ? "false" : "true", where
			}' "${files[@]}"
	fi
	printf '],"asked":%s}\n' "$#"
}

# rules_local_check - the candidate local.rules on stdin. Reports, as JSON,
# the lines that are no rule, a rule with no sid, a sid used twice, a sid that
# the merged set already uses, a sid outside the range kept for custom rules
# (a warning), and what `suricata -T` says about the file. It never writes
# anything; saving is `config-write local.rules`.
rules_local_check() {
	[[ $# -eq 0 ]] || fail 2 "rules-local check: the file comes on stdin"
	local tmp staged
	tmp=$(mktemp)
	head -c $((RULES_LOCAL_MAX_BYTES + 1)) >"$tmp"
	if (($(stat -c %s "$tmp") > RULES_LOCAL_MAX_BYTES)); then
		rm -f "$tmp"
		fail 5 "rules-local check: the file is larger than $RULES_LOCAL_MAX_BYTES bytes"
	fi
	local ruleset
	ruleset=$(path_suricata_ruleset)
	[[ -f "$ruleset" ]] || ruleset=/dev/null

	local report
	report=$(awk -v actions="$RULE_ACTIONS" -v lo="$RULES_LOCAL_SID_MIN" -v hi="$RULES_LOCAL_SID_MAX" -v ruleset="$ruleset" '
		BEGIN {
			re = "^[ \t]*(" actions ")[ \t]"
			rr = "^[# \t]*(" actions ")[ \t]"
			while ((getline line < ruleset) > 0) {
				if (line ~ rr && match(line, /sid: *[0-9]+/)) {
					s = substr(line, RSTART, RLENGTH); sub(/sid: */, "", s)
					if (!(s in used)) {
						m = ""
						if (match(line, /msg: *"([^"\\]|\\.)*"/)) { m = substr(line, RSTART, RLENGTH); sub(/msg: *"/, "", m); sub(/"$/, "", m); m = unq(m) }
						used[s] = m
					}
				}
			}
		}
		function unq(s) { gsub(/\\"/, "\"", s); gsub(/\\;/, ";", s); gsub(/\\\\/, "\\", s); return s }
		function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return s }
		function problem(n, kind, text) { printf "%s{\"line\":%d,\"kind\":\"%s\",\"text\":\"%s\"}", (np++ ? "," : ""), n, kind, esc(text) }
		function warning(n, text) { printf "%s{\"line\":%d,\"text\":\"%s\"}", (nw++ ? "," : ""), n, esc(text) > "/dev/stderr" }
		/^[ \t]*$/ { next }
		/^[ \t]*#/ { next }
		{
			if ($0 !~ re) { problem(NR, "not_a_rule", "this line is not a rule: it must start with an action such as alert"); next }
			rules++
			if (!match($0, /sid: *[0-9]+ *;/)) { problem(NR, "no_sid", "the rule has no sid: add sid:NNNNNNN; to its options"); next }
			s = substr($0, RSTART, RLENGTH); sub(/sid: */, "", s); sub(/ *;/, "", s)
			if (s in first) problem(NR, "duplicate", "sid " s " is already used on line " first[s] " of this file")
			else first[s] = NR
			if (s in used) problem(NR, "conflict", "sid " s " is already used by the rule set: " used[s])
			if (s + 0 < lo || s + 0 > hi) warning(NR, "sid " s " is outside " lo "-" hi ", the range kept for custom rules; a later rule update may use it")
		}
		END { printf "\n%d\n", rules + 0 }' "$tmp" 2>"$tmp.warn")
	local problems rules
	problems=$(head -n1 <<<"$report")
	rules=$(tail -n1 <<<"$report")
	local warnings
	warnings=$(paste -sd, - <"$tmp.warn")

	# suricata -T on the set with this candidate; its words are part of the
	# answer, and "not run" is said, not hidden.
	local check_ok=true check_run=true check_out="" rc=0
	staged=$(mktemp)
	cp "$tmp" "$staged"
	check_out=$(suricata_check_set local.rules "$staged" 2>&1) || rc=$?
	rm -f "$staged"
	if ((rc == 4)); then
		check_run=false
		check_out="Suricata is not installed here, so the file was not tested"
	elif ((rc != 0)); then
		check_ok=false
	fi
	local ok=true
	[[ -n "$problems" || "$check_ok" == false ]] && ok=false
	printf '{"ok":%s,"rules":%s,"problems":[%s],"warnings":[%s],"suricata":{"run":%s,"ok":%s,"output":"%s"}}\n' \
		"$ok" "$rules" "$problems" "$warnings" "$check_run" "$check_ok" "$(json_escape "$(printf '%s' "$check_out" | tail -n 20)")"
	rm -f "$tmp" "$tmp.warn"
}

RULES_FIND_MAX=50
RULES_FACETS_MAX=200

# rs_source_sids <name> - the sids of an enabled source, one per line, from
# its newest cache file; nothing when the source is unknown or not cached.
rs_source_sids() {
	local name="$1" n url file
	while IFS=$'\t' read -r n url; do
		[[ "$n" == "$name" ]] || continue
		[[ -n "$url" ]] || url=$(rs_index_url "$n")
		[[ -n "$url" ]] || return 0
		file=$(rs_cache_file "$url")
		[[ -n "$file" ]] || return 0
		rs_archive_rules "$file" | rs_rule_states /dev/stdin | cut -d' ' -f1
		return 0
	done < <(rs_enabled_sources)
}

# rules_find [--class NAME] [--source NAME] [--state enabled|disabled|any]
#            [--text TEXT]
# Finds rules in the merged set by their category (classtype), their source,
# their state and their text (a number is an exact sid). Disabled rules are
# found too: that is how one is found to be turned back on. At least one
# criterion is needed, and at most 50 rules come back.
rules_find() {
	local class="" source="" state=any text=""
	while (($#)); do
		case "$1" in
		--class | --source | --state | --text)
			(($# >= 2)) || fail 2 "rules-find: $1 needs a value"
			case "$1" in
			--class) class="$2" ;;
			--source) source="$2" ;;
			--state) state="$2" ;;
			--text) text="$2" ;;
			esac
			shift 2
			;;
		*) fail 2 "rules-find: unknown option: $1" ;;
		esac
	done
	[[ -n "$class$source$text" || "$state" != any ]] || fail 2 "rules-find: give --class, --source, --state or --text"
	[[ -z "$class" || "$class" =~ ^[A-Za-z0-9-]{1,64}$ ]] || fail 5 "rules-find: a category is letters, digits and -"
	[[ -z "$source" || "$source" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] || fail 5 "rules-find: not a source name"
	[[ "$state" == any || "$state" == enabled || "$state" == disabled ]] || fail 5 "rules-find: --state is enabled, disabled or any"
	[[ -z "$text" || "$text" =~ ^[A-Za-z0-9\ ._:=/@+,-]{1,100}$ ]] || fail 5 "rules-find: the text is up to 100 characters: letters, digits, space and . _ : = / @ + , -"
	local ruleset
	ruleset=$(path_suricata_ruleset)
	[[ -f "$ruleset" ]] || fail 4 "no rule set"

	local sids=""
	if [[ -n "$source" ]]; then
		sids=$(mktemp)
		rs_source_sids "$source" >"$sids"
		if [[ ! -s "$sids" ]]; then
			rm -f "$sids"
			printf '{"results":[],"truncated":false,"source_known":false}\n'
			return 0
		fi
	fi
	local out
	out=$(RF_CLASS="$class" RF_TEXT="$text" awk -v actions="$RULE_ACTIONS" -v max="$RULES_FIND_MAX" -v state="$state" -v sidfile="$sids" '
		BEGIN {
			re = "^[# \t]*(" actions ")[ \t]"
			cls = tolower(ENVIRON["RF_CLASS"]); q = tolower(ENVIRON["RF_TEXT"]); num = (q ~ /^[0-9]+$/)
			if (sidfile != "") { while ((getline l < sidfile) > 0) want[l] = 1; filter = 1 }
		}
		function unq(s) { gsub(/\\"/, "\"", s); gsub(/\\;/, ";", s); gsub(/\\\\/, "\\", s); return s }
		function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/[\001-\037]/, " ", s); return s }
		$0 ~ re && match($0, /sid: *[0-9]+/) {
			sid = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", sid)
			if (filter && !(sid in want)) next
			on = ($0 ~ /^[ \t]*#/) ? 0 : 1
			if (state == "enabled" && !on) next
			if (state == "disabled" && on) next
			c = ""
			if (match($0, /classtype: *[A-Za-z0-9-]+/)) { c = substr($0, RSTART, RLENGTH); sub(/classtype: */, "", c) }
			if (cls != "" && tolower(c) != cls) next
			msg = ""
			if (match($0, /msg: *"([^"\\]|\\.)*"/)) { msg = substr($0, RSTART, RLENGTH); sub(/msg: *"/, "", msg); sub(/"$/, "", msg); msg = unq(msg) }
			if (q != "") { if (num ? (sid != q) : (index(tolower(msg), q) == 0)) next }
			n++
			if (n > max) { more = 1; exit }
			printf "%s{\"sid\":%s,\"msg\":\"%s\",\"class\":\"%s\",\"enabled\":%s}", (n > 1 ? "," : ""), sid, esc(msg), esc(c), on ? "true" : "false"
		}
		END { printf "\n%s\n", more ? "true" : "false" }' "$ruleset")
	[[ -n "$sids" ]] && rm -f "$sids"
	printf '{"results":[%s],"truncated":%s,"source_known":true}\n' "$(head -n1 <<<"$out")" "$(tail -n1 <<<"$out")"
}

# rules_facets - what the filters of rules-find can be: the categories in
# the merged set with their counts (the 200 largest), and the enabled sources.
rules_facets() {
	[[ $# -eq 0 ]] || fail 2 "rules-facets: no arguments"
	local ruleset
	ruleset=$(path_suricata_ruleset)
	printf '{"classes":['
	if [[ -f "$ruleset" ]]; then
		awk -v actions="$RULE_ACTIONS" -v max="$RULES_FACETS_MAX" '
			BEGIN { re = "^[# \t]*(" actions ")[ \t]" }
			$0 ~ re && match($0, /classtype: *[A-Za-z0-9-]+/) { c = substr($0, RSTART, RLENGTH); sub(/classtype: */, "", c); n[c]++ }
			END {
				for (c in n) printf "%d\t%s\n", n[c], c | "sort -t\"\t\" -k1,1nr -k2,2"
				close("sort -t\"\t\" -k1,1nr -k2,2")
			}' "$ruleset" | head -n "$RULES_FACETS_MAX" | awk -F'\t' '{ printf "%s{\"name\":\"%s\",\"count\":%d}", (NR > 1 ? "," : ""), $2, $1 }'
	fi
	printf '],"sources":['
	local first=1 name url
	while IFS=$'\t' read -r name url; do
		[[ -n "$name" ]] || continue
		((first)) || printf ','
		first=0
		printf '"%s"' "$(json_escape "$name")"
	done < <(rs_enabled_sources)
	printf ']}\n'
}

cmd_rules_local() {
	[[ $# -ge 1 ]] || fail 2 "rules-local: check"
	local sub="$1"
	shift
	case "$sub" in
	check) rules_local_check "$@" ;;
	*) fail 2 "rules-local: unknown subcommand: $sub" ;;
	esac
}

# config_history <name> [<version>] - the saved versions of a config file,
# newest first, or the content of one. The versions are the backups every
# change makes (backups/<file>.<time>).
config_history() {
	[[ $# -ge 1 && $# -le 2 ]] || fail 2 "config-history: <name> [<version>]"
	local name="$1" version="${2:-}" path base dir f
	path=$(config_path "$name") || fail 5 "config-history: unknown file: $name"
	base=$(basename "$path")
	dir=$(path_backups_dir)
	if [[ -n "$version" ]]; then
		[[ "$version" =~ ^[0-9]{8}T[0-9]{6}Z(\.[0-9]+)?$ ]] || fail 5 "config-history: not a version id: $version"
		f="$dir/$base.$version"
		[[ -f "$f" ]] || fail 4 "config-history: no such version: $version"
		cat "$f"
		return 0
	fi
	printf '{"name":"%s","versions":[' "$(json_escape "$name")"
	local first=1 id size lines
	if [[ -d "$dir" ]]; then
		while IFS= read -r f; do
			id="${f##*/}"
			id="${id#"$base".}"
			[[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z(\.[0-9]+)?$ ]] || continue
			size=$(stat -c %s "$f")
			lines=$(wc -l <"$f")
			((first)) || printf ','
			first=0
			printf '{"id":"%s","time":"%s-%s-%sT%s:%s:%sZ","size":%s,"lines":%s}' "$id" "${id:0:4}" "${id:4:2}" "${id:6:2}" "${id:9:2}" "${id:11:2}" "${id:13:2}" "$size" "$lines"
		done < <(find "$dir" -maxdepth 1 -type f -name "$base.*" | sort -V -r)
	fi
	printf ']}\n'
}
