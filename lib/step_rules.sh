#!/usr/bin/env bash
# Rules: suricata-update sources from RULES_SOURCES/RULES_URLS,
# enable.conf from RULES_GROUPS, and the dpistack-rules timer
# (tech.md slice 3). suricata-update itself tests the new ruleset with
# `suricata -T` before replacing suricata.rules and keeps the old one
# on failure (--no-test is never passed), so step_rules.sh does not
# reimplement that rollback.

RULES_TIMER="dpistack-rules.timer"

rules_data_dir() { echo "${DPISTACK_ROOT}/var/lib/suricata"; }

# rules_update_command -> the exact suricata-update invocation used
# both for a one-off apply and inside the timer's service unit, so the
# two never drift apart.
RULES_UPDATE_ARGV=()

# rules_update_argv - fills RULES_UPDATE_ARGV, so callers run it as an
# array and nothing needs eval.
rules_update_argv() {
	RULES_UPDATE_ARGV=(suricata-update
		-D "$(rules_data_dir)"
		--suricata-conf "$(path_suricata_yaml)"
		--enable-conf "$(path_suricata_enable_conf)"
		--disable-conf "$(path_suricata_disable_conf)"
		--modify-conf "$(path_suricata_modify_conf)"
		--drop-conf "$(path_suricata_drop_conf)"
		-o "$(dirname "$(path_suricata_ruleset)")")
}

# rules_update_command - the same invocation as one shell-quoted line,
# for logs, dry-run output and the systemd unit.
rules_update_command() {
	rules_update_argv
	local line
	line=$(printf '%q ' "${RULES_UPDATE_ARGV[@]}")
	printf '%s' "${line% }"
}

rules_render_enable_conf() {
	local groups="${CONF[RULES_GROUPS]:-}"
	local g
	local IFS=','
	for g in $groups; do
		[[ -z "$g" ]] && continue
		echo "group:${g}.rules"
	done
}

rules_custom_source_name() {
	# rules_custom_source_name <index> -> stable, suricata-update-safe name
	printf 'dpistack-custom-%s' "$1"
}

rules_register_sources() {
	local data_dir
	data_dir=$(rules_data_dir)

	local name
	local IFS=','
	for name in ${CONF[RULES_SOURCES]:-}; do
		[[ -z "$name" ]] && continue
		run suricata-update enable-source -D "$data_dir" "$name"
	done

	local url i=1
	for url in ${CONF[RULES_URLS]:-}; do
		[[ -z "$url" ]] && continue
		run suricata-update add-source -D "$data_dir" "$(rules_custom_source_name "$i")" "$url"
		i=$((i + 1))
	done
}

rules_write_timer_unit() {
	local calendar="${CONF[RULES_UPDATE_CALENDAR]:-weekly}"
	{
		echo "[Unit]"
		echo "Description=dpistack periodic Suricata rules update"
		echo
		echo "[Timer]"
		echo "OnCalendar=${calendar}"
		echo "Persistent=true"
		echo
		echo "[Install]"
		echo "WantedBy=timers.target"
	} | dry_run_write "$(path_rules_timer_unit)"

	{
		echo "[Unit]"
		echo "Description=dpistack Suricata rules update"
		echo
		echo "[Service]"
		echo "Type=oneshot"
		echo "ExecStart=/bin/sh -c $(printf '%q' "$(rules_update_command)")"
	} | dry_run_write "$(path_rules_service_unit)"
}

rules_remove_timer_unit() {
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		return 0
	fi
	if [[ -f "$(path_rules_timer_unit)" || -f "$(path_rules_service_unit)" ]]; then
		run systemctl disable --now "$RULES_TIMER"
		rm -f "$(path_rules_timer_unit)" "$(path_rules_service_unit)"
		run systemctl daemon-reload
	fi
}

step_rules_check() {
	[[ -f "$(path_suricata_ruleset)" ]] || return 1

	local expected_enable_hash actual_enable_hash
	expected_enable_hash=$(rules_render_enable_conf | state_hash_content)
	if [[ -f "$(path_suricata_enable_conf)" ]]; then
		actual_enable_hash=$(state_hash_content <"$(path_suricata_enable_conf)")
	else
		actual_enable_hash=""
	fi
	[[ "$expected_enable_hash" == "$actual_enable_hash" ]] || return 1

	if [[ "${CONF[RULES_UPDATE]:-on}" == "on" ]]; then
		[[ -f "$(path_rules_timer_unit)" ]] || return 1
		grep -q "^OnCalendar=${CONF[RULES_UPDATE_CALENDAR]:-weekly}\$" "$(path_rules_timer_unit)" 2>/dev/null || return 1
	else
		[[ -f "$(path_rules_timer_unit)" ]] && return 1
	fi

	return 0
}

step_rules_apply() {
	if ! command -v suricata-update >/dev/null 2>&1; then
		pkg_install suricata-update
	fi

	rules_register_sources

	write_rendered_file "$(path_suricata_enable_conf)" "$(rules_render_enable_conf)"

	# Not inside $(...): the array has to be set in this shell.
	rules_update_argv
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		printf '+ %s\n' "$(rules_update_command)"
	else
		log "RUN" "$(rules_update_command)"
		if ! "${RULES_UPDATE_ARGV[@]}"; then
			echo "suricata-update завершился с ошибкой, прежний набор правил сохранён" >&2
			return 1
		fi
		run suricatasc -c ruleset-reload-nonblocking
	fi

	if [[ "${CONF[RULES_UPDATE]:-on}" == "on" ]]; then
		rules_write_timer_unit
		run systemctl daemon-reload
		run systemctl enable --now "$RULES_TIMER"
	else
		rules_remove_timer_unit
	fi

	return 0
}

step_rules_plan() {
	echo "rules: источники ${CONF[RULES_SOURCES]:-} + URL из RULES_URLS"
	echo "rules: enable.conf из групп ${CONF[RULES_GROUPS]:-}"
	if [[ "${CONF[RULES_UPDATE]:-on}" == "on" ]]; then
		echo "rules: таймер $RULES_TIMER, OnCalendar=${CONF[RULES_UPDATE_CALENDAR]:-weekly}"
	else
		echo "rules: RULES_UPDATE=off, таймер не создаётся/удаляется"
	fi
}
