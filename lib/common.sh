#!/usr/bin/env bash
# Shared primitives every step and lib file uses instead of calling
# system commands or writing files directly (tech.md section 3, 5.6).

# Single source of the program version; the menu header, usage and
# dpistack-ctl version all print it.
# shellcheck disable=SC2034 # read by menu.sh, install.sh and dpistack-ctl
DPISTACK_VERSION="0.3.2"

: "${DRY_RUN:=0}"

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
	# The status is read straight after the command: inside `if ! cmd`
	# $? is the negated result, so a failing command used to look like 0.
	"$@"
	local rc=$?
	if ((rc != 0)); then
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
	# {fd} picks a free descriptor; no eval, so odd characters in the
	# path cannot become code.
	local fd
	exec {fd}>"$lock_file"
	if ! flock -n "$fd"; then
		die 1 "another dpistack instance is running (lock: $lock_file)"
	fi
}

atomic_write() {
	# atomic_write <target-path> [mode] < content-on-stdin
	# mktemp makes the temp file 0600, and the rename would hand that mode
	# to the target: a rendered evebox.yaml became unreadable for the
	# evebox user. An explicit mode wins (secrets pass it so they are
	# never wider than intended, even for a moment); otherwise an existing
	# target keeps its mode and owner and a new file gets 0644.
	local target="$1" mode="${2:-}"
	local dir
	dir=$(dirname "$target")
	mkdir -p "$dir"
	local tmp
	tmp=$(mktemp "${dir}/.tmp.XXXXXX")
	local ok=0
	if [[ -n "$mode" ]]; then
		chmod "$mode" "$tmp" || ok=1
	elif [[ -e "$target" ]]; then
		chmod --reference="$target" "$tmp" || ok=1
		chown --reference="$target" "$tmp" 2>/dev/null || true
	else
		chmod 0644 "$tmp" || ok=1
	fi
	# A failed write (disk full) must not replace the target with a
	# truncated file.
	if ((ok != 0)) || ! cat >"$tmp" || ! mv -f "$tmp" "$target"; then
		rm -f "$tmp"
		return 1
	fi
}

# dry_run_write <path> [mode] - atomic_write that also honours --dry-run,
# printing "+ render <path>" instead of writing (5.6).
dry_run_write() {
	local path="$1" mode="${2:-}"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		printf '+ render %s\n' "$path"
		cat >/dev/null
		return 0
	fi
	atomic_write "$path" "$mode"
}

# write_rendered_file <path> <content> [mode]
# Any step that renders a config file uses this, not atomic_write
# directly, so the 5.4 manual-edit guard is applied uniformly: a file
# that was hand-edited since our last render is left alone with a
# notice unless --force is given (which backs it up first).
write_rendered_file() {
	local path="$1" content="$2" mode="${3:-}"
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

	printf '%s\n' "$content" | dry_run_write "$path" "$mode"
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
	local dest n=1
	dest="${backups_dir}/$(basename "$src").${ts}"
	# Two backups in one second must not collide: config-revert takes
	# the newest by `sort -V`, so a counter suffix keeps the order.
	while [[ -e "$dest" ]]; do
		dest="${backups_dir}/$(basename "$src").${ts}.${n}"
		n=$((n + 1))
	done
	cp -p "$src" "$dest"
}

# panel_auth_write <plaintext> - writes an argon2id hash (PHC string,
# the format golang.org/x/crypto/argon2 users parse) into panel.auth.
# The password goes to argon2 on stdin, never as an argument.
# 0640 root:dpistack (4.2); before the panel step creates the user the
# group is missing, and step_panel_apply fixes the group afterwards.
panel_auth_write() {
	local plaintext="$1"
	command -v argon2 >/dev/null 2>&1 || return 2
	local salt hash
	salt=$(head -c 16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')
	hash=$(printf '%s' "$plaintext" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -e) || return 1
	# shellcheck disable=SC2016 # literal PHC prefix, not an expansion
	[[ "$hash" == '$argon2id$'* ]] || return 1
	printf '%s\n' "$hash" | atomic_write "$(path_panel_auth)" 0640 || return 1
	if getent group dpistack >/dev/null 2>&1; then
		chown root:dpistack "$(path_panel_auth)" || return 1
	fi
	return 0
}

# conf_get <KEY> <default> - reads one key straight from dpistack.conf.
# The helper stays independent of the installer's schema loader.
conf_get() {
	local key="$1" default="$2" value=""
	local file
	file=$(path_conf)
	[[ -r "$file" ]] && value=$(grep -m1 "^${key}=" "$file" | cut -d= -f2-)
	value="${value%\"}"
	value="${value#\"}"
	echo "${value:-$default}"
}
