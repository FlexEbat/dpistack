#!/usr/bin/env bash
# Shared primitives every step and lib file uses instead of calling
# system commands or writing files directly (tech.md section 3, 5.6).

: "${DRY_RUN:=0}"
: "${DPISTACK_LOCK_FD:=200}"

log() {
	# log <level> <message>
	local level="$1"
	shift
	local msg="$*"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local line="${ts} [${level}] ${msg}"
	echo "$line" >&2
	local log_dir
	log_dir=$(path_log_dir)
	mkdir -p "$log_dir" 2>/dev/null || true
	echo "$line" >>"$(path_install_log)" 2>/dev/null || true
}

die() {
	# die <exit-code> <message>
	local code="$1"
	shift
	log "ERROR" "$*"
	exit "$code"
}

run() {
	# run <command...>
	# Dry-run prints "+ command" and does not execute (5.6). Real mode
	# executes and logs both the command and whether it failed.
	if [[ "$DRY_RUN" == "1" ]]; then
		printf '+ %s\n' "$*"
		return 0
	fi
	log "RUN" "$*"
	if ! "$@"; then
		local rc=$?
		log "ERROR" "command failed (rc=$rc): $*"
		return "$rc"
	fi
}

lock_acquire() {
	# Takes an flock on the dpistack lock file. A second concurrent
	# instance must exit 1 immediately (5.1, tested by tests/lock.bats).
	# The OS releases the flock on process exit, so there is no
	# matching lock_release: nothing else would ever call it.
	local lock_file
	lock_file=$(path_lock_file)
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
	eval "exec ${DPISTACK_LOCK_FD}>\"$lock_file\""
	if ! flock -n "$DPISTACK_LOCK_FD"; then
		die 1 "another dpistack instance is running (lock: $lock_file)"
	fi
}

atomic_write() {
	# atomic_write <target-path> < content-on-stdin
	local target="$1"
	local dir
	dir=$(dirname "$target")
	mkdir -p "$dir"
	local tmp
	tmp=$(mktemp "${dir}/.tmp.XXXXXX")
	cat >"$tmp"
	mv -f "$tmp" "$target"
}

# dry_run_write <path> - atomic_write that also honours --dry-run,
# printing "+ render <path>" instead of writing (5.6).
dry_run_write() {
	local path="$1"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		printf '+ render %s\n' "$path"
		cat >/dev/null
		return 0
	fi
	atomic_write "$path"
}

# write_rendered_file <path> <content>
# Any step that renders a config file uses this, not atomic_write
# directly, so the 5.4 manual-edit guard is applied uniformly: a file
# that was hand-edited since our last render is left alone with a
# notice unless --force is given (which backs it up first).
write_rendered_file() {
	local path="$1" content="$2"
	local new_hash
	new_hash=$(printf '%s\n' "$content" | state_hash_content)

	if [[ -f "$path" ]]; then
		local on_disk_hash last_hash
		on_disk_hash=$(state_hash_content <"$path")
		last_hash=$(state_file_hash "$path")
		if [[ -n "$last_hash" && "$on_disk_hash" != "$last_hash" && "${FORCE:-0}" != "1" ]]; then
			echo "  $path изменён вручную, оставляю как есть (нужен --force)" >&2
			return 0
		fi
		if [[ "$on_disk_hash" == "$new_hash" ]]; then
			return 0
		fi
		[[ "${FORCE:-0}" == "1" ]] && backup "$path"
	fi

	printf '%s\n' "$content" | dry_run_write "$path"
	state_set_file_hash "$path" "$new_hash"
}

backup() {
	# backup <path-to-existing-file>
	# Copies the file into backups/<basename>.<timestamp> before it gets
	# overwritten. No-op if the file does not exist yet.
	local src="$1"
	[[ -f "$src" ]] || return 0
	local backups_dir
	backups_dir=$(path_backups_dir)
	mkdir -p "$backups_dir"
	local ts
	ts=$(date -u +"%Y%m%dT%H%M%SZ")
	cp -p "$src" "${backups_dir}/$(basename "$src").${ts}"
}
