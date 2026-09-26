#!/usr/bin/env bash
# Flat "key=value" step-completion log, rewritten atomically. File
# render hashing (tech.md 5.4) lands here once a step actually renders
# something; no step does yet, so that part isn't built prematurely.

state_read_value() {
	# state_read_value <key>
	local key="$1"
	local f
	f=$(path_state_file)
	[[ -f "$f" ]] || return 0
	grep -m1 "^${key}=" "$f" | cut -d= -f2-
}

state_write_value() {
	# state_write_value <key> <value>
	local key="$1" value="$2"
	local f
	f=$(path_state_file)
	local tmp
	tmp=$(mktemp)
	if [[ -f "$f" ]]; then
		grep -v "^${key}=" "$f" >"$tmp" || true
	fi
	echo "${key}=${value}" >>"$tmp"
	atomic_write "$f" <"$tmp"
	rm -f "$tmp"
}

state_set_step_done() {
	local step="$1"
	state_write_value "step.${step}.status" "done"
	state_write_value "step.${step}.ts" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
