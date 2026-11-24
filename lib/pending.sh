#!/usr/bin/env bash
# Settings that an update brought or that were left empty. A new version can
# add keys, and a saved config can hold a key with no value where the program
# needs one. `install` never asked about them: it fills in the default, and
# the next write of dpistack.conf made them look chosen. This file finds them
# before that write and keeps the list in the state file (pending.keys), so
# `dpistack update-keys`, `dpistack update` and the panel can ask about them.
#
#   new    the key is not in the saved dpistack.conf at all
#   empty  the key is there with no value, its default is not empty, and an
#          empty value has no meaning of its own (schema_empty_meaning): the
#          program would silently use the default
#
# A key that does not apply to the config as it is (its component is off, its
# channel is not used) is never listed. Sourced by install.sh; it defines
# functions only.

# pending_scan - the pending keys of the saved config, "KEY:kind" one per
# line. Needs the layers loaded (layer_config_common) so that the skip
# rules see the config as it will be.
pending_scan() {
	local conf key value
	conf=$(path_conf)
	[[ -f "$conf" ]] || return 0
	for key in "${SCHEMA_KEYS[@]}"; do
		schema_is_secret "$key" && continue
		menu_key_skipped "$key" && continue
		if ! grep -q "^${key}=" "$conf"; then
			echo "$key:new"
			continue
		fi
		value=$(sed -n "s/^${key}=//p" "$conf" | tail -n 1)
		if [[ -z "$value" && -n "${SCHEMA_DEFAULT[$key]:-}" && -z "$(schema_empty_meaning "$key")" ]]; then
			echo "$key:empty"
		fi
	done
	return 0
}

# pending_record - keeps the scan in the state file, joined with what an
# earlier upgrade left that nobody answered yet. Called by `install` before
# it writes the config.
pending_record() {
	local scan old merged
	# a dry run changes nothing, and a host without a saved config has nothing to compare
	[[ "${DRY_RUN:-0}" != "1" && -f "$(path_conf)" ]] || return 0
	scan=$(pending_scan | tr '\n' ',')
	scan="${scan%,}"
	old=$(state_read_value pending.keys)
	merged=$(printf '%s,%s' "$old" "$scan" | tr ',' '\n' | awk -F: 'NF && !seen[$1]++' | tr '\n' ',')
	merged="${merged%,}"
	# nothing new and nothing recorded: the state file is not touched
	[[ -n "$merged" || -n "$old" ]] || return 0
	state_write_value pending.keys "$merged"
	return 0
}

# pending_list - the pending keys now, "KEY:kind" one per line: the state
# list and the empty ones of the config as it is, without the keys that
# since got a value or stopped applying.
pending_list() {
	local item key kind
	{
		state_read_value pending.keys | tr ',' '\n'
		pending_scan
	} | awk -F: 'NF && !seen[$1]++' | while IFS=: read -r key kind; do
		[[ -n "${SCHEMA_TYPE[$key]:-}" ]] || continue
		menu_key_skipped "$key" && continue
		item="$key:${kind:-new}"
		# an empty key that has a value now is answered
		if [[ "$kind" == empty && -n "${CONF[$key]:-}" ]]; then
			continue
		fi
		echo "$item"
	done
}

pending_clear() { state_write_value pending.keys ""; }

# pending_print <json:0|1> - the list with default and hint.
pending_print() {
	local json="$1" item key kind first=1 n=0
	local -a items=()
	mapfile -t items < <(pending_list)
	if ((json)); then
		printf '{"pending":['
		for item in "${items[@]}"; do
			key="${item%%:*}"
			kind="${item##*:}"
			((first)) || printf ','
			first=0
			printf '{"key":"%s","kind":"%s","default":"%s","hint":"%s"}' "$key" "$kind" \
				"$(json_escape "${SCHEMA_DEFAULT[$key]:-}")" "$(json_escape "${KEY_HINT[$key]:-}")"
		done
		printf ']}\n'
		return 0
	fi
	if ((${#items[@]} == 0)); then
		echo "no new or empty settings"
		return 0
	fi
	echo "${#items[@]} setting(s) are new in this version or empty; their default is used until you answer:"
	for item in "${items[@]}"; do
		key="${item%%:*}"
		kind="${item##*:}"
		n=$((n + 1))
		printf '  %s (%s, default: %s)\n' "$key" "$kind" "${SCHEMA_DEFAULT[$key]:-none}"
		[[ -n "${KEY_HINT[$key]:-}" ]] && printf '      %s\n' "${KEY_HINT[$key]}"
	done
	return 0
}

# pending_ask - asks every pending key, one by one: Enter keeps the default
# that is shown, a value is checked like in the menu. s keeps the defaults
# of the rest, x stops and leaves the rest pending. Returns 0 when it asked
# at least one and the config changed, 1 when nothing changed.
pending_ask() {
	local item key kind rc changed=0
	local -a items=()
	mapfile -t items < <(pending_list)
	((${#items[@]} > 0)) || {
		echo "no new or empty settings" >&2
		return 1
	}
	echo >&2
	menu_bold "${#items[@]} setting(s) are new in this version or empty" >&2
	echo >&2
	echo "  Enter keeps the default shown, - sets the default, s keeps the defaults of the rest, x stops here." >&2
	for item in "${items[@]}"; do
		key="${item%%:*}"
		kind="${item##*:}"
		# an empty key is offered its default, so Enter fixes it
		[[ "$kind" == empty && -z "${CONF[$key]:-}" ]] && config_set_kv "$key" "${SCHEMA_DEFAULT[$key]}"
		echo >&2
		echo "[$kind]" >&2
		menu_wizard_ask "$key"
		rc=$?
		changed=1
		((rc == 10)) && break
		((rc == 11)) && return 2
	done
	return $((changed ? 0 : 1))
}

# cmd_update_keys [--list|--json|--yes] - the update step.
cmd_update_keys() {
	local mode=ask arg
	for arg in "$@"; do
		case "$arg" in
		--list) mode=list ;;
		--json) mode=json ;;
		--yes | -y) mode=yes ;;
		*) die 2 "update-keys: [--list|--json|--yes]" ;;
		esac
	done
	# its log lines would sit in front of the JSON
	os_detect >/dev/null 2>&1
	layer_config_common
	case "$mode" in
	list)
		pending_print 0
		return 0
		;;
	json)
		pending_print 1
		return 0
		;;
	yes)
		# the defaults are the answer: write them down and stop asking
		validate_or_die
		config_write_conf "$(path_conf)"
		pending_clear
		echo "the defaults of the new or empty settings are kept"
		return 0
		;;
	esac
	have_input_source || die 2 "update-keys: no terminal to ask on, use --list, --json or --yes"
	menu_open_input
	local rc=0
	pending_ask || rc=$?
	menu_close_input
	if ((rc == 1)); then
		return 0
	fi
	validate_or_die
	config_write_conf "$(path_conf)"
	if ((rc == 0)); then
		pending_clear
	fi
	echo "saved"
	return 0
}

# pending_notice - the end of an install: what is still pending, in two lines.
pending_notice() {
	local n
	n=$(pending_list | wc -l)
	((n > 0)) || return 0
	echo "$n setting(s) are new in this version or empty and use their defaults: sudo dpistack update-keys"
	return 0
}
