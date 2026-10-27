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
		# PANEL_MODE (limited/unlimited) is gone since v0.23.0: an old file
		# still loads, the key is dropped.
		[[ "$key" == "PANEL_MODE" ]] && continue
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
		echo "bad --set, KEY=VALUE expected: $kv"
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

	# nginx takes the public port, the service moves to <public>+10000.
	if [[ "${CONF[ACCESS_MODE]:-localhost}" == "nginx" ]]; then
		local port_key
		for port_key in NTOPNG_PORT EVEBOX_PORT PANEL_PORT; do
			if [[ "${CONF[$port_key]:-0}" =~ ^[0-9]+$ ]] && ((${CONF[$port_key]:-0} > 55535)); then
				echo "ACCESS_MODE=nginx needs $port_key not above 55535 (the service listens on the port plus 10000)"
				errors=$((errors + 1))
			fi
		done
	fi

	if [[ "${CONF[EVEBOX_DB]:-}" == "elasticsearch" && -z "${CONF[EVEBOX_ES_URL]:-}" ]]; then
		echo "EVEBOX_DB=elasticsearch needs EVEBOX_ES_URL"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[METRICS_BACKEND]:-}" != "none" && "${CONF[METRICS_EXPORT]:-}" == "no" ]]; then
		echo "METRICS_BACKEND=${CONF[METRICS_BACKEND]} needs METRICS_EXPORT=yes (the backend has nothing to scrape)"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[SURICATA_MODE]:-ids}" == "ips" ]]; then
		if [[ "${CONF[SURICATA_RUNTIME]:-native}" == "docker" ]]; then
			echo "SURICATA_MODE=ips works only with SURICATA_RUNTIME=native (NFQUEUE and copy-mode are not supported in a container)"
			errors=$((errors + 1))
		fi
		if [[ "${CONF[IPS_METHOD]:-nfq}" == "afpacket" ]]; then
			local -a ips_ifaces=()
			IFS=',' read -ra ips_ifaces <<<"${CONF[IFACES]:-}"
			if ((${#ips_ifaces[@]} < 2 || ${#ips_ifaces[@]} % 2 != 0)); then
				echo "IPS_METHOD=afpacket pairs interfaces: IFACES needs an even number of interfaces (at least two)"
				errors=$((errors + 1))
			fi
		fi
	fi
	local ips_chain
	local -a ips_chains=()
	IFS=',' read -ra ips_chains <<<"${CONF[IPS_NFQ_CHAINS]:-INPUT,OUTPUT,FORWARD}"
	for ips_chain in "${ips_chains[@]}"; do
		if [[ ! "$ips_chain" =~ ^(INPUT|OUTPUT|FORWARD)$ ]]; then
			echo "IPS_NFQ_CHAINS: INPUT, OUTPUT, FORWARD are allowed, got $ips_chain"
			errors=$((errors + 1))
		fi
	done

	# VictoriaMetrics reads a bare number as months and the suffix m as
	# months, Prometheus reads m as minutes: only the suffixes both read the
	# same way (h, d, w, y) are allowed once a backend is installed.
	if [[ "${CONF[METRICS_BACKEND]:-none}" != "none" && ! "${CONF[METRICS_RETENTION]:-30d}" =~ ^[0-9]+[hdwy]$ ]]; then
		echo "METRICS_RETENTION=${CONF[METRICS_RETENTION]:-} with a metrics backend: a number with the suffix h, d, w or y is needed (for example 30d); backends read a bare number or m differently"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[EVE_ROTATE]:-}" == "size" && -z "${CONF[EVE_MAX_SIZE_MB]:-}" ]]; then
		echo "EVE_ROTATE=size needs EVE_MAX_SIZE_MB"
		errors=$((errors + 1))
	fi

	local bind_value="${CONF[BIND_ADDR]:-auto}" bind_open=0
	if [[ "$bind_value" != "auto" ]]; then
		local octet bad=0
		IFS=. read -ra _octets <<<"$bind_value"
		for octet in "${_octets[@]}"; do
			((10#$octet <= 255)) || bad=1
		done
		if ((bad)) || [[ "$bind_value" == "0.0.0.0" ]]; then
			echo "BIND_ADDR=$bind_value is not an address of a host; use auto or an IPv4 address of this machine"
			errors=$((errors + 1))
		elif [[ "$bind_value" != 127.* ]]; then
			bind_open=1
		fi
	fi
	if [[ "${CONF[ACCESS_MODE]:-}" == "nginx" ]]; then
		bind_open=0
	fi
	if { [[ "${CONF[ACCESS_MODE]:-}" != "localhost" ]] || ((bind_open)); } && [[ "${ACCESS_CONFIRM:-}" != "yes" && "${NON_INTERACTIVE:-0}" == "1" ]]; then
		echo "ACCESS_MODE=${CONF[ACCESS_MODE]} with BIND_ADDR=${bind_value} in non-interactive mode needs --set ACCESS_CONFIRM=yes"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[NDPI_ENABLE]:-no}" == "yes" && "${CONF[SURICATA_SOURCE]:-}" != "source" &&
		! -f "$(path_suricata_ndpi_plugin)" && "${NON_INTERACTIVE:-0}" == "1" ]]; then
		echo "NDPI_ENABLE=yes with SURICATA_SOURCE=${CONF[SURICATA_SOURCE]:-} does not give ndpi.so; use SURICATA_SOURCE=source or build the plugin beforehand"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[SURICATA_ENABLE]:-yes}" == "no" ]]; then
		local dep
		for dep in NDPI_ENABLE RULES_ENABLE; do
			if [[ "${CONF[$dep]:-no}" == "yes" ]]; then
				echo "SURICATA_ENABLE=no with ${dep}=yes: ${dep%_ENABLE} works only together with Suricata; set ${dep}=no"
				errors=$((errors + 1))
			fi
		done
	fi

	if [[ "${CONF[NGINX_TLS]:-none}" == "existing" && (-z "${CONF[NGINX_CERT]:-}" || -z "${CONF[NGINX_KEY]:-}") ]]; then
		echo "NGINX_TLS=existing needs NGINX_CERT and NGINX_KEY"
		errors=$((errors + 1))
	fi

	if [[ "${CONF[EVE_FILE]:-yes}" == "no" && "${CONF[EVEBOX_DB]:-sqlite}" == "sqlite" ]]; then
		echo "EVE_FILE=no with EVEBOX_DB=sqlite: EveBox cannot read events (eve.json is not written). Enable EVE_FILE=yes or choose EVEBOX_DB=elasticsearch"
		errors=$((errors + 1))
	fi

	local channel
	local -a channels=()
	IFS=',' read -ra channels <<<"${CONF[ALERT_CHANNELS]:-}"
	for channel in "${channels[@]}"; do
		case "$channel" in
		panel | log | tg | mail) ;;
		*)
			echo "ALERT_CHANNELS: unknown channel '$channel' (panel, log, tg, mail are allowed)"
			errors=$((errors + 1))
			;;
		esac
	done
	if [[ ",${CONF[ALERT_CHANNELS]:-}," == *",tg,"* ]]; then
		if [[ -z "${SECRETS[ALERT_TG_TOKEN]:-}" || -z "${CONF[ALERT_TG_CHAT_ID]:-}" ]]; then
			echo "ALERT_CHANNELS contains tg: needs ALERT_TG_TOKEN and ALERT_TG_CHAT_ID"
			errors=$((errors + 1))
		fi
	fi
	if [[ ",${CONF[ALERT_CHANNELS]:-}," == *",mail,"* ]]; then
		if [[ -z "${SECRETS[ALERT_SMTP_URL]:-}" || -z "${CONF[ALERT_MAIL_TO]:-}" || -z "${CONF[ALERT_MAIL_FROM]:-}" ]]; then
			echo "ALERT_CHANNELS contains mail: needs ALERT_SMTP_URL, ALERT_MAIL_TO and ALERT_MAIL_FROM"
			errors=$((errors + 1))
		fi
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

# The applied config lives in state as applied.<KEY>=<value>, so a
# later `dpistack reconfigure` can diff dpistack.conf (already
# edited by config-write) against what the system was last built from.
config_snapshot_applied() {
	local f tmp key lock_fd
	f=$(path_state_file)
	# Same lock as state_write_value: the watchdog rewrites this file too,
	# and an unlocked read-modify-write here could drop its update.
	mkdir -p "$(dirname "$f")"
	exec {lock_fd}>"${f}.lock"
	flock -x "$lock_fd"
	tmp=$(mktemp)
	if [[ -f "$f" ]]; then
		grep -v '^applied\.' "$f" >"$tmp" || true
	fi
	for key in $(printf '%s\n' "${!CONF[@]}" | sort); do
		printf 'applied.%s=%s\n' "$key" "${CONF[$key]}" >>"$tmp"
	done
	atomic_write "$f" 0600 <"$tmp"
	rm -f "$tmp"
	exec {lock_fd}>&-
}

config_write_secrets() {
	local path="$1"
	local key
	{
		for key in $(printf '%s\n' "${!SECRETS[@]}" | sort); do
			[[ -n "${SECRETS[$key]}" ]] || continue
			printf '%s=%s\n' "$key" "${SECRETS[$key]}"
		done
	} | atomic_write "$path" 0600
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
			printf '  %s=set\n' "$key"
		else
			printf '  %s=not set\n' "$key"
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
# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure after calling config_diff_and_steps
CONFIG_AFFECTED_STEPS=()

config_diff_and_steps() {
	local old_file="$1"
	# Old side = the applied snapshot when there is one, else the file.
	local snapshot_file=""
	if grep -q '^applied\.' "$(path_state_file)" 2>/dev/null; then
		snapshot_file=$(mktemp)
		grep '^applied\.' "$(path_state_file)" | sed 's/^applied\.//' >"$snapshot_file"
		old_file="$snapshot_file"
	fi
	CONFIG_CHANGE_WEIGHT="none"
	CONFIG_CHANGED_KEYS=()
	CONFIG_AFFECTED_STEPS=()
	declare -A OLD
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		OLD["$key"]="$value"
	done <"$old_file"
	[[ -n "$snapshot_file" ]] && rm -f "$snapshot_file"

	local -a changed=()
	for key in "${!CONF[@]}"; do
		if [[ "${OLD[$key]-__unset__}" != "${CONF[$key]}" ]]; then
			changed+=("$key")
		fi
	done

	if [[ "${#changed[@]}" -eq 0 ]]; then
		echo "no changes"
		return 0
	fi
	# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure
	CONFIG_CHANGED_KEYS=("${changed[@]}")

	echo "Changed keys:"
	local k
	for k in "${changed[@]}"; do
		printf '  %s: %s -> %s\n' "$k" "${OLD[$k]-(not set)}" "${CONF[$k]}"
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
	# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure
	# In the order of the pipeline (suricata before rules, access before
	# panel...), not in the arbitrary order of an associative array; a step
	# that is not in STEPS_ORDER goes last, sorted.
	CONFIG_AFFECTED_STEPS=()
	for step in "${STEPS_ORDER[@]:-}"; do
		[[ -n "${steps_seen[$step]:-}" ]] && CONFIG_AFFECTED_STEPS+=("$step")
	done
	for step in $(printf '%s\n' "${!steps_seen[@]}" | sort); do
		[[ " ${CONFIG_AFFECTED_STEPS[*]} " == *" $step "* ]] || CONFIG_AFFECTED_STEPS+=("$step")
	done

	echo "Affected steps:"
	printf '  %s\n' "${CONFIG_AFFECTED_STEPS[@]}"

	echo "Change type: $overall_weight"
	return 0
}
