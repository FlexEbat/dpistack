#!/usr/bin/env bash
# Flat "key=value" step-completion log, rewritten atomically, plus
# render-hash tracking for idempotency (tech.md 5.4).

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

# Render-hash tracking for idempotency and the "manually edited file"
# guard (tech.md 5.4). Added back in slice 2 once step_suricata.sh
# actually renders something; slice 1 removed these as dead code
# because nothing called them yet.

state_file_hash() {
	# state_file_hash <rendered-file-path> -> stored hash or empty
	state_read_value "filehash.$(echo "$1" | tr '/' '_')"
}

state_set_file_hash() {
	local path="$1" hash="$2"
	state_write_value "filehash.$(echo "$path" | tr '/' '_')" "$hash"
}

state_hash_content() {
	# state_hash_content < content-on-stdin -> sha256 hex
	sha256sum | cut -d' ' -f1
}
