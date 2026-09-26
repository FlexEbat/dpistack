#!/usr/bin/env bash
# Layers dpistack.conf together (schema defaults -> dpistack.conf ->
# secrets.conf/env -> --config -> --set -> interactive answers),
# validates the result against lib/schema.sh, and can diff two
# configs for `reconfigure` (tech.md 5.1, 5.3, 4.3).

declare -A CONF SECRETS
ACCESS_CONFIRM=""

config_reset() {
	CONF=()
	SECRETS=()
	ACCESS_CONFIRM=""
}

config_set_kv() {
	# config_set_kv <key> <value>
	# Routes to CONF or SECRETS depending on the schema.
	local key="$1" value="$2"
	if schema_known "$key" && schema_is_secret "$key"; then
		SECRETS["$key"]="$value"
	else
		CONF["$key"]="$value"
	fi
}

config_load_defaults() {
	local key
	for key in "${SCHEMA_KEYS[@]}"; do
		config_set_kv "$key" "${SCHEMA_DEFAULT[$key]}"
	done
}

# config_load_kv_file <path>
# Reads KEY=value lines (tech.md 4.3: one per line, no quotes, no
# substitution), skipping blanks and comments, and applies each
# through config_set_kv so secrets land in the right array.
config_load_kv_file() {
	local file="$1"
	[[ -f "$file" ]] || return 0
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		config_set_kv "$key" "$value"
	done <"$file"
}

config_apply_env_secrets() {
	local key
	for key in "${SCHEMA_KEYS[@]}"; do
		schema_is_secret "$key" || continue
		local env_value="${!key:-}"
		[[ -n "$env_value" ]] && SECRETS["$key"]="$env_value"
	done
}

# config_apply_set <KEY=VALUE>
config_apply_set() {
	local kv="$1"
	if [[ "$kv" != *=* ]]; then
		echo "неверный --set, ожидался KEY=VALUE: $kv"
		return 1
	fi
	local key="${kv%%=*}" value="${kv#*=}"
	if [[ "$key" == "ACCESS_CONFIRM" ]]; then
		# Documented in 4.3's cross-checks, not in the key table: it
		# confirms ACCESS_MODE != localhost non-interactively and is
		# never written to dpistack.conf.
		ACCESS_CONFIRM="$value"
		return 0
	fi
	config_set_kv "$key" "$value"
}

# config_ask_basic [advanced]
# Linear question flow over basic keys (or basic+advanced), current
# value shown as the default, Enter keeps it (tech.md 5.0 semantics,
# without the full-screen menu that ships in a later slice).
config_ask_basic() {
	local include_advanced="${1:-no}"
	local input="${DPISTACK_INPUT:-/dev/tty}"
	local key current answer
	# Open once and read sequential lines; re-redirecting a fresh `read`
	# onto the file on every question would rewind it back to line 1.
	exec 9<"$input"
	for key in "${SCHEMA_KEYS[@]}"; do
		if [[ "$include_advanced" != "yes" ]] && ! schema_is_basic "$key"; then
			continue
		fi
		if schema_is_secret "$key"; then
			current="${SECRETS[$key]:-}"
		else
			current="${CONF[$key]:-}"
		fi
		printf '%s [%s]: ' "$key" "$current" >&2
		if ! IFS= read -r answer <&9; then
			answer=""
		fi
		[[ -n "$answer" ]] && config_set_kv "$key" "$answer"
	done
	exec 9<&-
}

# config_validate
# Prints every problem found (schema + cross-field, tech.md 4.3) and
# returns the number of errors.
config_validate() {
	local errors=0
	local key msg

	for key in "${!CONF[@]}"; do
		if ! msg=$(schema_validate_one "$key" "${CONF[$key]}"); then
			echo "$msg"
			errors=$((errors + 1))
		fi
	done

	if [[ "${CONF[EVEBOX_DB]:-}" == "elasticsearch" && -z "${CONF[EVEBOX_ES_URL]:-}" ]]; then
		echo "EVEBOX_DB=elasticsearch требует EVEBOX_ES_URL"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[METRICS_BACKEND]:-}" != "none" && "${CONF[METRICS_EXPORT]:-}" == "no" ]]; then
		echo "METRICS_BACKEND=${CONF[METRICS_BACKEND]} требует METRICS_EXPORT=yes (бэкенду нечего собирать)"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[EVE_ROTATE]:-}" == "size" && -z "${CONF[EVE_MAX_SIZE_MB]:-}" ]]; then
		echo "EVE_ROTATE=size требует EVE_MAX_SIZE_MB"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[ACCESS_MODE]:-}" != "localhost" && "${ACCESS_CONFIRM:-}" != "yes" && "${NON_INTERACTIVE:-0}" == "1" ]]; then
		echo "ACCESS_MODE=${CONF[ACCESS_MODE]} в неинтерактивном режиме требует --set ACCESS_CONFIRM=yes"
		errors=$((errors + 1))
	fi

	return "$errors"
}

METRICS_TOKEN_JUST_GENERATED=0

config_generate_metrics_token_if_needed() {
	METRICS_TOKEN_JUST_GENERATED=0
	if [[ "${CONF[METRICS_EXPORT]:-}" == "yes" && -z "${SECRETS[METRICS_TOKEN]:-}" ]]; then
		SECRETS[METRICS_TOKEN]=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
		# shellcheck disable=SC2034 # read by install.sh right after this call
		METRICS_TOKEN_JUST_GENERATED=1
	fi
}

# config_write_conf <path>
# Deterministic, sorted output so two runs with the same values give
# byte-identical files (tech.md 5.1 criterion: repeat -y = same conf).
config_write_conf() {
	local path="$1"
	local key
	{
		for key in $(printf '%s\n' "${!CONF[@]}" | sort); do
			printf '%s=%s\n' "$key" "${CONF[$key]}"
		done
	} | atomic_write "$path"
	chmod 0644 "$path"
}

config_write_secrets() {
	local path="$1"
	local key
	{
		for key in $(printf '%s\n' "${!SECRETS[@]}" | sort); do
			[[ -n "${SECRETS[$key]}" ]] || continue
			printf '%s=%s\n' "$key" "${SECRETS[$key]}"
		done
	} | atomic_write "$path"
	chmod 0600 "$path"
}

# config_print_summary
# Secrets never show their value, only whether one is set (tech.md 5.0).
config_print_summary() {
	local key
	for key in $(printf '%s\n' "${!CONF[@]}" | sort); do
		printf '  %s=%s\n' "$key" "${CONF[$key]}"
	done
	for key in $(printf '%s\n' "${!SECRETS[@]}" | sort); do
		if [[ -n "${SECRETS[$key]}" ]]; then
			printf '  %s=задан\n' "$key"
		else
			printf '  %s=не задан\n' "$key"
		fi
	done
}

# config_diff_and_steps <old-conf-file>
# Compares CONF (already layered/validated) against a previously
# applied dpistack.conf, prints "KEY: old -> new", and returns the
# affected steps and worst weight on stdout after a marker line
# (tech.md 5.3).
# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure after calling config_diff_and_steps
CONFIG_CHANGE_WEIGHT="none"
# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure after calling config_diff_and_steps
CONFIG_CHANGED_KEYS=()

config_diff_and_steps() {
	local old_file="$1"
	CONFIG_CHANGE_WEIGHT="none"
	CONFIG_CHANGED_KEYS=()
	declare -A OLD
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		OLD["$key"]="$value"
	done <"$old_file"

	local -a changed=()
	for key in "${!CONF[@]}"; do
		if [[ "${OLD[$key]-__unset__}" != "${CONF[$key]}" ]]; then
			changed+=("$key")
		fi
	done

	if [[ "${#changed[@]}" -eq 0 ]]; then
		echo "изменений нет"
		return 0
	fi
	# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure
	CONFIG_CHANGED_KEYS=("${changed[@]}")

	echo "Изменённые ключи:"
	local k
	for k in "${changed[@]}"; do
		printf '  %s: %s -> %s\n' "$k" "${OLD[$k]-(не задан)}" "${CONF[$k]}"
	done

	declare -A steps_seen
	local overall_weight="light"
	for k in "${changed[@]}"; do
		schema_known "$k" || continue
		local step
		for step in ${SCHEMA_STEPS[$k]}; do
			steps_seen["$step"]=1
		done
		[[ "${SCHEMA_WEIGHT[$k]}" == "heavy" ]] && overall_weight="heavy"
	done
	# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure
	CONFIG_CHANGE_WEIGHT="$overall_weight"

	echo "Затронутые шаги:"
	for step in "${!steps_seen[@]}"; do
		echo "  $step"
	done | sort

	echo "Тип изменения: $overall_weight"
	return 0
}
