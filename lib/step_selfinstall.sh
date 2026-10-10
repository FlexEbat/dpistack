#!/usr/bin/env bash
# "selfinstall" step (tech.md 5.2): copies the installer and its helpers
# to /usr/local/lib/dpistack/installer/ and puts the persistent commands
# in /usr/local/sbin: `dpistack` (a symlink to install.sh, so $0 is
# "dpistack"), plus dpistack-ctl and dpistack-watch. After this the stack
# no longer needs the original clone or archive.

SELFINSTALL_PAYLOAD=(install.sh lib templates bin tests/data)
SELFINSTALL_HASH_KEY="selfinstall.tree_hash"

# Hash of everything that would be copied: when it is unchanged the step
# copies nothing (slice 15 criterion 2).
selfinstall_source_hash() {
	(cd "$SCRIPT_DIR" && find "${SELFINSTALL_PAYLOAD[@]}" -type f 2>/dev/null |
		LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
}

# Running from the installed copy: it already is the target.
selfinstall_is_target() {
	[[ "$(readlink -f "$SCRIPT_DIR")" == "$(readlink -f "$(path_installer_copy_dir)")" ]]
}

step_selfinstall_check() {
	selfinstall_is_target && return 0
	[[ -L "$(path_dpistack_bin)" && -x "$(path_ctl_bin)" && -x "$(path_watch_bin)" ]] || return 1
	[[ -x "$(path_installer_copy_dir)/install.sh" ]] || return 1
	[[ "$(state_read_value "$SELFINSTALL_HASH_KEY")" == "$(selfinstall_source_hash)" ]]
}

step_selfinstall_apply() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "+ copy ${SELFINSTALL_PAYLOAD[*]} to $(path_installer_copy_dir)"
		return 0
	fi
	selfinstall_is_target && return 0

	local dest staged
	dest=$(path_installer_copy_dir)
	staged="${dest}.new"
	rm -rf "$staged"
	mkdir -p "$staged"
	(cd "$SCRIPT_DIR" && cp -a --parents "${SELFINSTALL_PAYLOAD[@]}" "$staged") || return 1
	chmod 0755 "$staged/install.sh" "$staged/bin/dpistack-ctl" "$staged/bin/dpistack-watch"
	# Swap the whole tree, so a failed copy never leaves half an installer.
	rm -rf "${dest}.old"
	[[ -d "$dest" ]] && mv "$dest" "${dest}.old"
	mv "$staged" "$dest"
	rm -rf "${dest}.old"

	run install -D -m 0755 "$dest/bin/dpistack-ctl" "$(path_ctl_bin)" || return 1
	run install -D -m 0755 "$dest/bin/dpistack-watch" "$(path_watch_bin)" || return 1
	run ln -sfn "$dest/install.sh" "$(path_dpistack_bin)" || return 1
	state_write_value "$SELFINSTALL_HASH_KEY" "$(selfinstall_source_hash)"
	return 0
}

step_selfinstall_plan() {
	echo "selfinstall: копия установщика в $(path_installer_copy_dir), команды dpistack, dpistack-ctl, dpistack-watch в $(path_sbin_dir)"
}
