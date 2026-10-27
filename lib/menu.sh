#!/usr/bin/env bash
# Plain-Bash text menu for `install`/`reconfigure` (tech.md 5.0, 5.1,
# 5.3). No dialog/whiptail/ncurses/cursor codes: every screen is just
# printed again, so it works over SSH, in tmux, and stays in scrollback.

MENU_GROUPS=(capture components eve rules access metrics watch tests)
declare -A MENU_GROUP_TITLE=(
	[capture]="Capture and mode"
	[components]="Components and sources"
	[eve]="EVE and storage"
	[rules]="Rules"
	[access]="Access"
	[metrics]="Metrics"
	[watch]="Watch and alerts"
	[tests]="Tests"
)

MENU_SHOW_ADVANCED=0
MENU_DIRTY=0
declare -A MENU_OLD_CONF # snapshot for reconfigure's "~" marker and diff
MENU_PANEL_PASSWORD=""   # plaintext, held only in memory until hashed
MENU_PANEL_PASSWORD_SET=0

menu_color_on() {
	[[ -z "${NO_COLOR:-}" && "${CLI_NO_COLOR:-0}" != "1" && -t 1 ]]
}
menu_c() {
	# menu_c <code> <text>
	if menu_color_on; then
		printf '\033[%sm%s\033[0m' "$1" "$2"
	else
		printf '%s' "$2"
	fi
}
menu_bold() { menu_c 1 "$1"; }
menu_red() { menu_c 31 "$1"; }

MENU_INPUT_OPENED=0
menu_open_input() {
	[[ "$MENU_INPUT_OPENED" == "1" ]] && return 0
	exec 8<"${DPISTACK_INPUT:-${DPISTACK_TTY_DEV:-/dev/tty}}"
	MENU_INPUT_OPENED=1
	trap 'menu_on_interrupt' INT
}
menu_close_input() {
	[[ "$MENU_INPUT_OPENED" == "1" ]] && exec 8<&-
	MENU_INPUT_OPENED=0
}

# menu_on_interrupt - Ctrl+C: change nothing, leave no temp files.
menu_on_interrupt() {
	echo >&2
	echo "interrupted, nothing changed" >&2
	menu_close_input
	exit 130
}

MENU_EOF=0

# menu_read <varname> [prompt] - reads one line from fd 8 straight into
# $varname (no command substitution: that runs in a subshell, so an
# EOF flag set inside it would never reach the caller). Sets MENU_EOF
# on a failed read; $varname is cleared to "" in that case.
menu_read() {
	local __menu_read_var="$1" prompt="${2:-}"
	[[ -n "$prompt" ]] && printf '%s' "$prompt" >&2
	# shellcheck disable=SC2229 # intentional indirection: read into the variable named by $__menu_read_var
	if IFS= read -r "$__menu_read_var" <&8; then
		MENU_EOF=0
	else
		MENU_EOF=1
		printf -v "$__menu_read_var" '%s' ""
	fi
}

# menu_die_on_eof - call right after menu_read in every screen loop:
# a closed/exhausted input source must stop the menu instead of
# spinning forever on "" being treated as an unknown choice.
menu_die_on_eof() {
	if [[ "$MENU_EOF" == "1" ]]; then
		echo "end of input, leaving without applying" >&2
		menu_close_input
		exit 2
	fi
}

# menu_confirm <question> [y|n] - a yes/no question before an action (v0.25.0:
# every action of the menu asks first). `0` and `q` cancel like `n`; Enter
# takes the default (second argument, `y` unless said). Returns 0 on yes.
# DPISTACK_MENU_ASSUME_YES=1 answers yes without asking (a test hook: the
# older menu tests drive the screens with fixed input lines).
menu_confirm() {
	local question="$1" default="${2:-y}" answer hint
	[[ "${DPISTACK_MENU_ASSUME_YES:-0}" == "1" ]] && return 0
	if [[ "$default" == "y" ]]; then hint="[Y/n, 0 = cancel]"; else hint="[y/N, 0 = cancel]"; fi
	while true; do
		menu_read answer "$question $hint "
		menu_die_on_eof
		case "${answer,,}" in
		"")
			[[ "$default" == "y" ]]
			return
			;;
		y | yes) return 0 ;;
		n | no | 0 | q | cancel) return 1 ;;
		*) echo "  answer y, n or 0" >&2 ;;
		esac
	done
}

# menu_read_secret <varname> [prompt] - like menu_read, but suppresses
# echo on a real tty (a file source like DPISTACK_INPUT has nothing to
# suppress).
menu_read_secret() {
	local __menu_read_var="$1" prompt="${2:-}"
	[[ -n "$prompt" ]] && printf '%s' "$prompt" >&2
	local is_tty=0
	[[ -t 8 ]] && is_tty=1
	[[ "$is_tty" == "1" ]] && stty -echo 2>/dev/null
	# shellcheck disable=SC2229 # intentional indirection: read into the variable named by $__menu_read_var
	if IFS= read -r "$__menu_read_var" <&8; then
		MENU_EOF=0
	else
		MENU_EOF=1
		printf -v "$__menu_read_var" '%s' ""
	fi
	[[ "$is_tty" == "1" ]] && {
		stty echo 2>/dev/null
		echo >&2
	}
}

# shellcheck disable=SC2034 # read by install.sh after panel_password_apply
PANEL_PASSWORD_JUST_GENERATED=0
# shellcheck disable=SC2034 # read by install.sh after panel_password_apply
PANEL_PASSWORD_GENERATED_VALUE=""

# panel_password_apply - called from cmd_install/cmd_reconfigure after
# validation. The hash is argon2id (4.5 panel-passwd, 9), so the
# plaintext never reaches dpistack.conf, secrets.conf or the logs.
panel_password_apply() {
	local plaintext=""
	# --dry-run must not write panel.auth, install argon2 or print a
	# password: a generated one would be shown but never stored, so the
	# real run would then create a different one (R81).
	[[ "${DRY_RUN:-0}" == "1" ]] && return 0
	if [[ "$MENU_PANEL_PASSWORD_SET" == "1" ]]; then
		plaintext="$MENU_PANEL_PASSWORD"
	elif [[ "${NON_INTERACTIVE:-0}" == "1" && ! -f "$(path_panel_auth)" ]]; then
		if [[ -n "${DPISTACK_PANEL_PASSWORD:-}" ]]; then
			plaintext="$DPISTACK_PANEL_PASSWORD"
		else
			plaintext=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
			# shellcheck disable=SC2034 # read by install.sh after panel_password_apply
			PANEL_PASSWORD_JUST_GENERATED=1
			# shellcheck disable=SC2034 # read by install.sh after panel_password_apply
			PANEL_PASSWORD_GENERATED_VALUE="$plaintext"
		fi
	else
		return 0
	fi

	command -v argon2 >/dev/null 2>&1 || pkg_install argon2
	panel_auth_write "$plaintext" || die 1 "could not write the panel password hash (argon2)"
	MENU_PANEL_PASSWORD=""
}

menu_draft_save() {
	local key
	{
		for key in $(printf '%s\n' "${!CONF[@]}" | sort); do
			printf '%s=%s\n' "$key" "${CONF[$key]}"
		done
	} | atomic_write "$(path_conf_draft)" 0600
}

menu_draft_delete() { rm -f "$(path_conf_draft)"; }

menu_mark_for_key() {
	local key="$1" mark="" current
	if schema_is_secret "$key"; then
		current="${SECRETS[$key]:-}"
	else
		current="${CONF[$key]:-}"
	fi
	if schema_validate_one "$key" "$current" >/dev/null; then :; else mark="!"; fi
	if [[ -n "${MENU_OLD_CONF[$key]+x}" ]]; then
		[[ "$current" != "${MENU_OLD_CONF[$key]}" ]] && mark="~${mark}"
	elif [[ -n "${SCHEMA_DEFAULT[$key]+x}" && "$current" != "${SCHEMA_DEFAULT[$key]}" ]]; then
		mark="*${mark}"
	fi
	printf '%s' "$mark"
}

menu_problems() { config_validate; }

menu_problems_count() {
	local out
	out=$(config_validate)
	[[ -z "$out" ]] && {
		echo 0
		return
	}
	printf '%s\n' "$out" | wc -l
}

menu_group_summary() {
	# One short line per group for the main screen's right column.
	case "$1" in
	capture) echo "${CONF[SURICATA_MODE]^^}, ${CONF[IFACES]:-?}" ;;
	components) echo "Suricata: ${CONF[SURICATA_SOURCE]}, nDPI: $([[ ${CONF[NDPI_ENABLE]} == yes ]] && echo yes || echo no)" ;;
	eve)
		local n
		n=$(tr ',' '\n' <<<"${CONF[EVE_TYPES]}" | grep -c .)
		echo "$n types, rotation ${CONF[EVE_ROTATE]}"
		;;
	rules) echo "${CONF[RULES_SOURCES]}, ${CONF[RULES_UPDATE_CALENDAR]}" ;;
	access) echo "${CONF[ACCESS_MODE]}" ;;
	metrics) echo "export: $([[ ${CONF[METRICS_EXPORT]} == yes ]] && echo yes || echo no), backend: ${CONF[METRICS_BACKEND]}" ;;
	watch) echo "${CONF[ALERT_CHANNELS]}" ;;
	tests) echo "after install: $([[ ${CONF[TEST_ON_INSTALL]} == yes ]] && echo yes || echo no)" ;;
	esac
}

# menu_edit_key <key> - the single-key editing loop (5.0): Enter keeps
# the value, '-' resets to default, '?' repeats the hint, anything else
# is validated immediately; an invalid value is rejected with the
# allowed list and the old value stays.
menu_edit_key() {
	local key="$1"
	while true; do
		local current="${CONF[$key]:-}"
		local opts="${SCHEMA_OPTIONS[$key]}"
		echo "$key (now: ${current:-<empty>}, default: ${SCHEMA_DEFAULT[$key]:-<empty>})" >&2
		[[ -n "$opts" ]] && echo "  options: $opts" >&2
		local answer
		if schema_is_secret "$key"; then
			menu_read_secret answer "New value (Enter or cancel = leave, - resets, ? help): "
		else
			menu_read answer "New value (Enter or cancel = leave, - resets, ? help): "
		fi
		menu_die_on_eof
		case "$answer" in
		"" | cancel) return 0 ;;
		"?")
			echo "  ${key}: group ${SCHEMA_GROUP[$key]}, type ${SCHEMA_TYPE[$key]}" >&2
			continue
			;;
		"-")
			menu_confirm "Reset $key to the default (${SCHEMA_DEFAULT[$key]:-<empty>})?" || {
				echo "  not changed" >&2
				return 0
			}
			config_set_kv "$key" "${SCHEMA_DEFAULT[$key]}"
			menu_draft_save
			return 0
			;;
		*)
			local err
			if err=$(schema_validate_one "$key" "$answer"); then
				if schema_is_secret "$key"; then
					menu_confirm "Set $key (a secret)?" || {
						echo "  not changed" >&2
						return 0
					}
				else
					menu_confirm "Set $key = $answer?" || {
						echo "  not changed" >&2
						return 0
					}
				fi
				config_set_kv "$key" "$answer"
				menu_draft_save
				MENU_DIRTY=1
				return 0
			else
				echo "  $err" >&2
				continue
			fi
			;;
		esac
	done
}

menu_section_keys() {
	local group="$1" key
	for key in "${SCHEMA_KEYS[@]}"; do
		[[ "${SCHEMA_GROUP[$key]}" == "$group" ]] || continue
		[[ "$key" == "METRICS_TOKEN" ]] && continue # generated, not editable (5.0)
		if [[ "$MENU_SHOW_ADVANCED" != "1" ]] && ! schema_is_basic "$key"; then
			continue
		fi
		echo "$key"
	done
}

menu_section_screen() {
	local group="$1"
	while true; do
		echo >&2
		menu_bold "${MENU_GROUP_TITLE[$group]}" >&2
		echo >&2
		local -a keys=()
		mapfile -t keys < <(menu_section_keys "$group")
		local i=1 key
		for key in "${keys[@]}"; do
			local mark
			mark=$(menu_mark_for_key "$key")
			local shown
			if schema_is_secret "$key"; then
				shown=$([[ -n "${SECRETS[$key]:-}" ]] && echo set || echo "not set")
			else
				shown="${CONF[$key]:-}"
			fi
			printf '  %2d) %-28s = %s %s\n' "$i" "$key" "$shown" "$mark" >&2
			i=$((i + 1))
		done
		echo "  a) $([[ $MENU_SHOW_ADVANCED == 1 ]] && echo "hide" || echo "show") advanced   0) back (Enter too)   ?) help   q) quit" >&2
		local problems
		problems=$(menu_problems_count)
		if [[ "$problems" -gt 0 ]]; then
			menu_red "Problems: $problems" >&2
			echo >&2
		else
			echo "Problems: $problems" >&2
		fi
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		"" | 0) return 0 ;;
		q) menu_quit_confirm && exit 0 ;;
		a)
			MENU_SHOW_ADVANCED=$((1 - MENU_SHOW_ADVANCED))
			continue
			;;
		'?')
			echo "  Number - edit a key; Enter/0 - back; a - show/hide advanced." >&2
			continue
			;;
		*)
			# 10#: "08" is eight, not a bad octal number, and "010" is ten.
			if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#keys[@]})); then
				menu_edit_key "${keys[$((10#$choice - 1))]}"
			else
				echo "  unclear choice: $choice" >&2
			fi
			;;
		esac
	done
}

menu_quit_confirm() {
	[[ "$MENU_DIRTY" != "1" ]] && return 0
	local answer
	menu_read answer "There are unapplied edits. Leave without applying? [y/N] "
	[[ "$answer" =~ ^[yY] ]]
}

menu_panel_password_screen() {
	while true; do
		local p1 p2
		menu_read_secret p1 "Panel password (!cancel = leave without setting): "
		menu_die_on_eof
		[[ "$p1" == "!cancel" ]] && return 0
		if [[ -z "$p1" ]]; then
			echo "  an empty password is not accepted" >&2
			continue
		fi
		menu_read_secret p2 "Repeat the password: "
		if [[ "$p1" != "$p2" ]]; then
			echo "  the passwords do not match" >&2
			continue
		fi
		menu_confirm "Use this password for the panel?" || {
			echo "  password not set" >&2
			return 0
		}
		MENU_PANEL_PASSWORD="$p1"
		MENU_PANEL_PASSWORD_SET=1
		MENU_DIRTY=1
		return 0
	done
}

# menu_pick_bind - which address the web services listen on: this machine
# only (127.0.0.1 / all addresses in lan mode) or one of its own addresses.
menu_pick_bind() {
	local -a ifaces=() addrs=()
	local line n=0 answer
	while read -r line; do
		[[ -n "$line" ]] || continue
		ifaces+=("${line%% *}")
		addrs+=("${line#* }")
	done < <(access_local_addresses)
	((${#addrs[@]})) || return 0
	echo "  Listen address (BIND_ADDR):" >&2
	echo "    0) auto: 127.0.0.1 (this machine only), or every address in lan mode" >&2
	for n in "${!addrs[@]}"; do
		printf '    %d) %s on %s\n' "$((n + 1))" "${addrs[$n]}" "${ifaces[$n]}" >&2
	done
	menu_read answer "Listen address [number or address, Enter=${CONF[BIND_ADDR]}]: "
	[[ -n "$answer" ]] || return 0
	if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer <= ${#addrs[@]})); then
		if ((answer == 0)); then answer="auto"; else answer="${addrs[$((answer - 1))]}"; fi
	fi
	local err
	if err=$(schema_validate_one BIND_ADDR "$answer"); then
		config_set_kv BIND_ADDR "$answer"
		MENU_DIRTY=1
	else
		echo "  $err" >&2
	fi
}

# menu_ask_yes_no <KEY> <question> - a yes/no question that sets KEY.
menu_ask_yes_no() {
	local key="$1" question="$2" answer
	menu_read answer "$question [y/n, Enter=${CONF[$key]/yes/y}]: "
	case "$answer" in
	y | Y | yes) config_set_kv "$key" yes && MENU_DIRTY=1 ;;
	n | N | no) config_set_kv "$key" no && MENU_DIRTY=1 ;;
	esac
}

# menu_pick_monitoring - the optional metrics stack: a storage (Prometheus or
# VictoriaMetrics), Grafana and node_exporter, each chosen on its own.
menu_pick_monitoring() {
	echo "  Metrics stack (each part is optional and chosen separately):" >&2
	local backend err
	menu_read backend "Metrics storage [none/victoriametrics/prometheus, Enter=${CONF[METRICS_BACKEND]}]: "
	if [[ -n "$backend" ]]; then
		if err=$(schema_validate_one METRICS_BACKEND "$backend"); then
			config_set_kv METRICS_BACKEND "$backend"
			MENU_DIRTY=1
		else
			echo "  $err" >&2
		fi
	fi
	menu_ask_yes_no GRAFANA_ENABLE "Install Grafana (dashboards)"
	menu_ask_yes_no NODE_EXPORTER_ENABLE "Install node_exporter (host metrics)"
}

# menu_quick_install - 5.1 "Quick install": interfaces (ip -o link,
# no lo, default-route one marked), Suricata source, access mode, which
# panel (full or lite), panel password; everything else keeps its default.
menu_quick_install() {
	echo >&2
	menu_bold "Quick install" >&2
	echo >&2
	local default_iface
	default_iface=$(ip -4 route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)

	local -a ifaces=()
	while IFS= read -r line; do
		local name="${line#*: }"
		name="${name%%:*}"
		[[ -z "$name" || "$name" == "lo" ]] && continue
		ifaces+=("$name")
	done < <(ip -o link show 2>/dev/null)

	local i=1 name
	for name in "${ifaces[@]}"; do
		local tag=""
		[[ "$name" == "$default_iface" ]] && tag=" (default route)"
		echo "  $i) $name$tag" >&2
		i=$((i + 1))
	done
	local sel
	menu_read sel "Interfaces (numbers, comma separated): "
	local -a chosen=()
	local n
	IFS=',' read -ra sel_nums <<<"$sel"
	for n in "${sel_nums[@]}"; do
		n="${n// /}"
		[[ "$n" =~ ^[0-9]+$ ]] && ((10#$n >= 1 && 10#$n <= ${#ifaces[@]})) && chosen+=("${ifaces[$((10#$n - 1))]}")
	done
	if [[ "${#chosen[@]}" -gt 0 ]]; then
		local joined
		joined=$(
			IFS=,
			echo "${chosen[*]}"
		)
		config_set_kv IFACES "$joined"
		MENU_DIRTY=1
	fi

	local src
	menu_read src "Suricata source [source/oisf/distro, Enter=${CONF[SURICATA_SOURCE]}]: "
	if [[ -n "$src" ]]; then
		local err
		if err=$(schema_validate_one SURICATA_SOURCE "$src"); then
			config_set_kv SURICATA_SOURCE "$src"
			MENU_DIRTY=1
		else
			echo "  $err" >&2
		fi
	fi

	local mode
	menu_read mode "Access mode [localhost/lan/nginx, Enter=${CONF[ACCESS_MODE]}]: "
	if [[ -n "$mode" ]]; then
		local err2
		if err2=$(schema_validate_one ACCESS_MODE "$mode"); then
			config_set_kv ACCESS_MODE "$mode"
			MENU_DIRTY=1
		else
			echo "  $err2" >&2
		fi
	fi

	if [[ "${CONF[ACCESS_MODE]}" != "nginx" ]]; then
		menu_pick_bind
	fi

	menu_pick_monitoring

	echo "  Panel: full (rich design, effects) or lite (same features, plain light page)" >&2
	local edition
	menu_read edition "Panel [full/lite, Enter=${CONF[PANEL_EDITION]}]: "
	if [[ -n "$edition" ]]; then
		local err3
		if err3=$(schema_validate_one PANEL_EDITION "$edition"); then
			config_set_kv PANEL_EDITION "$edition"
			MENU_DIRTY=1
		else
			echo "  $err3" >&2
		fi
	fi

	menu_panel_password_screen
	menu_draft_save
}

menu_check_system_screen() {
	menu_confirm "Check the system (nothing is changed)?" || return 0
	local reasons
	reasons=$(step_preflight_reasons)
	echo >&2
	if [[ -z "$reasons" ]]; then
		echo "preflight: no remarks" >&2
	else
		echo "preflight:" >&2
		echo "  ${reasons//$'\n'/$'\n  '}" >&2
	fi
	local _enter
	menu_read _enter "Enter to continue"
}

menu_plan_screen() {
	menu_confirm "Show the plan (nothing is changed)?" || return 0
	echo >&2
	run_plan >&2
	local _enter
	menu_read _enter "Enter to continue"
}

menu_save_to_file_screen() {
	local path
	menu_read path "File path (Enter = cancel): "
	[[ -z "$path" ]] && return 0
	menu_confirm "Write the config to $path?" || return 0
	config_write_conf "$path"
	echo "  saved to $path" >&2
}

menu_load_from_file_screen() {
	local path
	menu_read path "File path (Enter = cancel): "
	[[ -z "$path" ]] && return 0
	[[ -f "$path" ]] || {
		echo "  file not found" >&2
		return 0
	}
	menu_confirm "Load the values from $path (they become edits)?" || return 0
	config_load_kv_file "$path"
	local errs
	errs=$(config_validate)
	if [[ -n "$errs" ]]; then
		echo "  the loaded file has errors:" >&2
		echo "  $errs" >&2
	fi
	MENU_DIRTY=1
	menu_draft_save
}

# ------------------------------------------------------------------
# Choosing components (v0.25.0): every part is switched on or off on its
# own. A switched-off part is skipped by the installer; what is already
# installed stays (removing is `uninstall`).
# ------------------------------------------------------------------
MENU_COMPONENTS=(
	"SURICATA_ENABLE|Suricata (IDS/IPS engine)"
	"NDPI_ENABLE|nDPI plugin for Suricata"
	"RULES_ENABLE|Rules and their update"
	"EVEBOX_ENABLE|EveBox (alert viewer)"
	"NTOPNG_ENABLE|ntopng with Redis (traffic monitor)"
	"PANEL_ENABLE|Control panel"
	"WATCH_ENABLE|Watchdog"
	"GRAFANA_ENABLE|Grafana (dashboards)"
	"NODE_EXPORTER_ENABLE|node_exporter (host metrics)"
)

menu_toggle_component() {
	local key="$1" label="$2" cur new extra=""
	cur="${CONF[$key]:-yes}"
	if [[ "$cur" == "yes" ]]; then new=no; else new=yes; fi
	if [[ "$new" == "yes" && ("$key" == "NDPI_ENABLE" || "$key" == "RULES_ENABLE") &&
		"${CONF[SURICATA_ENABLE]:-yes}" == "no" ]]; then
		echo "  $label works only together with Suricata: switch Suricata on first" >&2
		return 0
	fi
	if [[ "$key" == "SURICATA_ENABLE" && "$new" == "no" ]]; then
		extra=" (nDPI and the rules go off with it)"
	fi
	menu_confirm "Switch $label $([[ $new == yes ]] && echo on || echo off)?$extra" || {
		echo "  not changed" >&2
		return 0
	}
	config_set_kv "$key" "$new"
	if [[ "$key" == "SURICATA_ENABLE" && "$new" == "no" ]]; then
		config_set_kv NDPI_ENABLE no
		config_set_kv RULES_ENABLE no
	fi
	[[ "$new" == "no" ]] && echo "  note: anything already installed stays; use uninstall to remove it" >&2
	MENU_DIRTY=1
	menu_draft_save
}

menu_components_screen() {
	while true; do
		echo >&2
		menu_bold "Choose components" >&2
		echo >&2
		local i=1 row key label
		for row in "${MENU_COMPONENTS[@]}"; do
			key="${row%%|*}"
			label="${row#*|}"
			printf '  %2d) [%s] %s\n' "$i" "$([[ ${CONF[$key]:-yes} == yes ]] && echo x || echo ' ')" "$label" >&2
			i=$((i + 1))
		done
		printf '  %2d) %-34s %s\n' "$i" "Metrics storage" "${CONF[METRICS_BACKEND]:-none}" >&2
		echo >&2
		echo "  Number - switch on/off (asks first)   s) all settings of the components" >&2
		echo "  0) back (Enter too)   ?) help   q) quit" >&2
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		"" | 0) return 0 ;;
		q) menu_quit_confirm && {
			menu_close_input
			exit 0
		} ;;
		s) menu_section_screen components ;;
		'?') echo "  Each part is chosen on its own; unchecked parts are skipped by the installer." >&2 ;;
		*)
			if [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice >= 1 && 10#$choice <= ${#MENU_COMPONENTS[@]})); then
				row="${MENU_COMPONENTS[$((10#$choice - 1))]}"
				menu_toggle_component "${row%%|*}" "${row#*|}"
			elif [[ "$choice" =~ ^[0-9]+$ ]] && ((10#$choice == ${#MENU_COMPONENTS[@]} + 1)); then
				menu_edit_key METRICS_BACKEND
			else
				echo "  unclear choice: $choice" >&2
			fi
			;;
		esac
	done
}

# ------------------------------------------------------------------
# Guided setup (v0.25.0): asks every setting that applies to the chosen
# components, group by group. Enter keeps the value, - resets to the
# default, s skips the rest of the group, x leaves the guided setup.
# ------------------------------------------------------------------

# menu_key_skipped <KEY> - 0 when the key does not apply to the config as it is.
menu_key_skipped() {
	local k="$1" y=yes n=no
	local suri="${CONF[SURICATA_ENABLE]:-yes}"
	case "$k" in
	METRICS_TOKEN) return 0 ;;
	SURICATA_RUNTIME | SURICATA_SOURCE | SURICATA_VERSION | SURICATA_MODE | IFACES | BPF_FILTER | HOME_NET | \
		EVE_SYSLOG | EVE_REDIS | EVE_ROTATE | EVE_KEEP | EVE_MAX_SIZE_MB | STATS_INTERVAL_SEC | TEST_*)
		[[ "$suri" == "$n" ]] && return 0
		;;
	IPS_METHOD | IPS_NFQ_CHAINS)
		[[ "$suri" == "$n" || "${CONF[SURICATA_MODE]:-ids}" != "ips" ]] && return 0
		;;
	NDPI_ENABLE) [[ "$suri" == "$n" ]] && return 0 ;;
	NDPI_SOURCE | NDPI_VERSION) [[ "$suri" == "$n" || "${CONF[NDPI_ENABLE]:-yes}" == "$n" ]] && return 0 ;;
	RULES_ENABLE) [[ "$suri" == "$n" ]] && return 0 ;;
	RULES_*) [[ "$suri" == "$n" || "${CONF[RULES_ENABLE]:-yes}" == "$n" ]] && return 0 ;;
	EVEBOX_ENABLE) ;;
	EVEBOX_ES_URL) [[ "${CONF[EVEBOX_ENABLE]:-yes}" == "$n" || "${CONF[EVEBOX_DB]:-sqlite}" != "elasticsearch" ]] && return 0 ;;
	EVEBOX_*) [[ "${CONF[EVEBOX_ENABLE]:-yes}" == "$n" ]] && return 0 ;;
	NTOPNG_ENABLE) ;;
	NTOPNG_*) [[ "${CONF[NTOPNG_ENABLE]:-yes}" == "$n" ]] && return 0 ;;
	PANEL_ENABLE) ;;
	PANEL_* | METRICS_EXPORT) [[ "${CONF[PANEL_ENABLE]:-yes}" == "$n" ]] && return 0 ;;
	LAN_CIDR) [[ "${CONF[ACCESS_MODE]:-localhost}" != "lan" ]] && return 0 ;;
	NGINX_MANAGE | NGINX_TLS) [[ "${CONF[ACCESS_MODE]:-localhost}" != "nginx" ]] && return 0 ;;
	NGINX_CERT | NGINX_KEY) [[ "${CONF[ACCESS_MODE]:-localhost}" != "nginx" || "${CONF[NGINX_TLS]:-none}" != "existing" ]] && return 0 ;;
	METRICS_BACKEND_RUNTIME | METRICS_BACKEND_PORT | METRICS_RETENTION) [[ "${CONF[METRICS_BACKEND]:-none}" == "none" ]] && return 0 ;;
	NODE_EXPORTER_ENABLE | GRAFANA_ENABLE | WATCH_ENABLE | METRICS_BACKEND) ;;
	NODE_EXPORTER_*) [[ "${CONF[NODE_EXPORTER_ENABLE]:-no}" == "$n" ]] && return 0 ;;
	GRAFANA_*) [[ "${CONF[GRAFANA_ENABLE]:-no}" == "$n" ]] && return 0 ;;
	ALERT_TG_*) [[ "${CONF[WATCH_ENABLE]:-yes}" == "$n" || ",${CONF[ALERT_CHANNELS]:-}," != *",tg,"* ]] && return 0 ;;
	ALERT_MAIL_* | ALERT_SMTP_URL) [[ "${CONF[WATCH_ENABLE]:-yes}" == "$n" || ",${CONF[ALERT_CHANNELS]:-}," != *",mail,"* ]] && return 0 ;;
	WATCH_* | ALERT_*) [[ "${CONF[WATCH_ENABLE]:-yes}" == "$n" ]] && return 0 ;;
	esac
	: "$y"
	return 1
}

# menu_wizard_ask <KEY> -> 0 go on, 10 skip the group, 11 leave the wizard.
menu_wizard_ask() {
	local key="$1" answer err
	while true; do
		local shown="${CONF[$key]:-}"
		schema_is_secret "$key" && shown=$([[ -n "${SECRETS[$key]:-}" ]] && echo set || echo "not set")
		echo >&2
		echo "$key (now: ${shown:-<empty>}, default: ${SCHEMA_DEFAULT[$key]:-<empty>})" >&2
		[[ -n "${SCHEMA_OPTIONS[$key]}" ]] && echo "  options: ${SCHEMA_OPTIONS[$key]}" >&2
		if schema_is_secret "$key"; then
			menu_read_secret answer "  value (Enter keeps, - default, s skip group, x leave setup, ? help): "
		else
			menu_read answer "  value (Enter keeps, - default, s skip group, x leave setup, ? help): "
		fi
		menu_die_on_eof
		case "$answer" in
		"") return 0 ;;
		s) return 10 ;;
		x) return 11 ;;
		'?')
			echo "  group ${SCHEMA_GROUP[$key]}, type ${SCHEMA_TYPE[$key]}, level ${SCHEMA_LEVEL[$key]}" >&2
			;;
		-)
			menu_confirm "Reset $key to the default?" || continue
			config_set_kv "$key" "${SCHEMA_DEFAULT[$key]}"
			MENU_DIRTY=1
			menu_draft_save
			return 0
			;;
		*)
			if err=$(schema_validate_one "$key" "$answer"); then
				if schema_is_secret "$key"; then
					menu_confirm "Set $key (a secret)?" || continue
				else
					menu_confirm "Set $key = $answer?" || continue
				fi
				config_set_kv "$key" "$answer"
				MENU_DIRTY=1
				menu_draft_save
				return 0
			fi
			echo "  $err" >&2
			;;
		esac
	done
}

menu_wizard() {
	echo >&2
	menu_bold "Guided setup" >&2
	echo >&2
	echo "  Every setting is asked, group by group. Settings of parts you switched off are skipped." >&2
	menu_components_screen
	local g key rc
	for g in "${MENU_GROUPS[@]}"; do
		[[ "$g" == "components" ]] && continue
		echo >&2
		menu_bold "== ${MENU_GROUP_TITLE[$g]} ==" >&2
		echo >&2
		menu_confirm "Go through this group?" || continue
		for key in "${SCHEMA_KEYS[@]}"; do
			[[ "${SCHEMA_GROUP[$key]}" == "$g" ]] || continue
			menu_key_skipped "$key" && continue
			menu_wizard_ask "$key"
			rc=$?
			((rc == 10)) && break
			if ((rc == 11)); then
				menu_confirm "Leave the guided setup (answers so far are kept)?" && return 0
			fi
		done
	done
	if [[ "$MENU_PANEL_PASSWORD_SET" != "1" ]] && menu_confirm "Set the panel password now?"; then
		menu_panel_password_screen
	fi
	menu_draft_save
}

# menu_main_screen -> 0 (user chose "Install") or exits the process.
menu_main_screen() {
	while true; do
		echo >&2
		echo "$(menu_bold "dpistack v${DPISTACK_VERSION}") | $OS_ID ${OS_VERSION_ID:-}, $(uname -m) | systemd: $(command -v systemctl >/dev/null && echo yes || echo no)" >&2
		echo "Install. Config: $(path_conf) (not created)" >&2
		echo >&2
		echo "  1) Quick install" >&2
		local i=2 g
		for g in "${MENU_GROUPS[@]}"; do
			printf '  %2d) %-30s %s\n' "$i" "${MENU_GROUP_TITLE[$g]}" "$(menu_group_summary "$g")" >&2
			i=$((i + 1))
		done
		printf '  %2d) %-30s %s\n' "$i" "Panel password" "$([[ $MENU_PANEL_PASSWORD_SET == 1 ]] && echo "set" || echo "not set")" >&2
		echo >&2
		echo "  m) Choose components   w) Guided setup (asks every setting)" >&2
		echo "  c) Check the system   p) Plan   s) Save to file   l) Load from file" >&2
		echo "  i) Install             q) Quit" >&2
		local problems
		problems=$(menu_problems_count)
		echo >&2
		if [[ "$problems" -gt 0 ]]; then
			menu_red "Problems ($problems): $(menu_problems | head -1)" >&2
			echo >&2
		else
			echo "Problems ($problems)" >&2
		fi
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		1) menu_quick_install ;;
		m) menu_components_screen ;;
		w) menu_wizard ;;
		c) menu_check_system_screen ;;
		p) menu_plan_screen ;;
		s) menu_save_to_file_screen ;;
		l) menu_load_from_file_screen ;;
		q) menu_quit_confirm && {
			menu_close_input
			exit 0
		} ;;
		i)
			if [[ "$problems" != "0" ]]; then
				echo "  cannot install while there are problems" >&2
				continue
			fi
			if [[ "$MENU_PANEL_PASSWORD_SET" != "1" ]]; then
				echo "  installation is unavailable without a panel password" >&2
				continue
			fi
			# A busy port is a warning with a choice here, not a stop later.
			preflight_resolve_ports_interactive || true
			return 0
			;;
		*)
			# Only a number goes into the arithmetic: "zz" there is a bash
			# error that ends the whole menu.
			local idx=0
			[[ "$choice" =~ ^[0-9]+$ ]] && idx=$((10#$choice - 1))
			if [[ "$choice" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "${#MENU_GROUPS[@]}" ]]; then
				menu_section_screen "${MENU_GROUPS[$((idx - 1))]}"
			elif [[ "$choice" == "$((${#MENU_GROUPS[@]} + 2))" ]]; then
				menu_panel_password_screen
			else
				echo "  unclear choice: $choice" >&2
			fi
			;;
		esac
	done
}

menu_found_install_screen() {
	while true; do
		echo >&2
		menu_bold "dpistack v${DPISTACK_VERSION} | Installation found" >&2
		echo >&2
		echo "  1) Configure   2) Apply the current config again   3) Control menu   4) Quit" >&2
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		1) return 10 ;; # caller switches to the reconfigure menu
		2) return 11 ;; # idempotent re-apply, no questions
		3) return 12 ;; # caller opens the management menu
		4 | q)
			menu_close_input
			exit 0
			;;
		*) echo "  unclear choice: $choice" >&2 ;;
		esac
	done
}

# menu_run_install - entry point for `install.sh install` without -y.
# Returns 0 once the user chose "Install"; the caller continues
# into the normal validate/summary/preflight/apply pipeline (5.1 item
# 1 onward), the same code -y runs directly.
menu_run_install() {
	menu_open_input

	if [[ -f "$(path_conf)" ]]; then
		menu_found_install_screen
		local rc=$?
		if [[ "$rc" == "11" ]]; then
			NON_INTERACTIVE=1 # "apply current config again" asks nothing
			menu_close_input
			return 0
		fi
		if [[ "$rc" == "12" ]]; then
			menu_run_manage
			exit 0
		fi
		# rc=10 (configure) falls through to the reconfigure menu below.
	elif [[ -f "$(path_conf_draft)" ]]; then
		local answer
		menu_read answer "Continue the draft? [Y/n] "
		if [[ "$answer" =~ ^[nN] ]]; then
			menu_draft_delete
			config_reset
			config_load_defaults
			config_apply_env_secrets
		else
			config_load_kv_file "$(path_conf_draft)"
		fi
	fi

	if [[ -f "$(path_conf)" ]]; then
		for key in "${!CONF[@]}"; do MENU_OLD_CONF[$key]="${CONF[$key]}"; done
		menu_reconfigure_screen
	else
		if [[ "${DPISTACK_MENU_ASSUME_YES:-0}" != "1" ]] && menu_confirm "Run the guided setup first (asks every setting, you can leave at any time)?"; then
			menu_wizard
		fi
		menu_main_screen
	fi

	menu_draft_delete
	menu_close_input
	return 0
}

# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure
MENU_ALREADY_CONFIRMED=0

# menu_reconfigure_confirm_and_validate - runs entirely inside the
# menu's own input loop (fd 8), so it never needs cmd_reconfigure to
# reread DPISTACK_INPUT afterwards. Returns 1 (stay in the menu) on
# "no changes", a declined heavy confirmation, or a failed suricata -T;
# only a real go-ahead returns 0.
menu_reconfigure_confirm_and_validate() {
	config_diff_and_steps "$(path_conf)" >/dev/null
	if [[ "$CONFIG_CHANGE_WEIGHT" == "none" ]]; then
		echo "  no changes" >&2
		return 1
	fi

	if [[ "$CONFIG_CHANGE_WEIGHT" == "heavy" ]]; then
		echo "  Heavy changes will affect the steps: ${CONFIG_AFFECTED_STEPS[*]}" >&2
		local answer
		menu_read answer "  Continue? [y/N] "
		menu_die_on_eof
		if [[ ! "$answer" =~ ^[yY] ]]; then
			echo "  cancelled" >&2
			return 1
		fi
	fi

	local step
	for step in "${CONFIG_AFFECTED_STEPS[@]}"; do
		if [[ "$step" == "suricata" ]]; then
			if ! suricata_validate_render "$(suricata_render_yaml)"; then
				echo "  suricata -T failed on the new suricata.yaml, the edits stay in the menu (see the output above)" >&2
				return 1
			fi
		fi
	done

	# shellcheck disable=SC2034 # read by install.sh's cmd_reconfigure
	MENU_ALREADY_CONFIRMED=1
	return 0
}

menu_diff_screen() {
	echo >&2
	config_diff_and_steps "$(path_conf)" >&2
	local _enter
	menu_read _enter "Enter to continue"
}

# menu_reconfigure_screen - 5.3's section screen. `0) Back` only makes
# sense when opened from the control menu (not built until slice 15),
# so a direct `dpistack reconfigure` behaves like `q` there, per spec.
menu_reconfigure_screen() {
	while true; do
		echo >&2
		menu_bold "dpistack v${DPISTACK_VERSION}" >&2
		echo " | Configuring an existing installation" >&2
		echo "Config: $(path_conf)" >&2
		echo >&2
		local i=1 g
		for g in "${MENU_GROUPS[@]}"; do
			printf '  %2d) %-30s %s\n' "$i" "${MENU_GROUP_TITLE[$g]}" "$(menu_group_summary "$g")" >&2
			i=$((i + 1))
		done
		printf '  %2d) %-30s %s\n' "$i" "Panel password" "change" >&2
		echo >&2
		echo "  m) Choose components   w) Guided setup (asks every setting)" >&2
		echo "  d) Changes (diff)   a) Apply   r) Discard edits" >&2
		echo "  s) Save to file   l) Load from file   q) Quit$([[ "$MENU_BACK_ENABLED" == "1" ]] && echo "   b) Back")" >&2
		local changed=0 key
		for key in "${!CONF[@]}"; do
			[[ "${CONF[$key]}" != "${MENU_OLD_CONF[$key]:-}" ]] && changed=$((changed + 1))
		done
		local rc_problems
		rc_problems=$(menu_problems_count)
		if [[ "$rc_problems" -gt 0 ]]; then
			echo "Edits: $changed key(s). $(menu_red "Problems: $rc_problems")" >&2
		else
			echo "Edits: $changed key(s). Problems: $rc_problems" >&2
		fi
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		m) menu_components_screen ;;
		w) menu_wizard ;;
		d) menu_diff_screen ;;
		a)
			preflight_resolve_ports_interactive || true
			if menu_reconfigure_confirm_and_validate; then
				return 0 # caller writes config.sh and applies the affected steps
			fi
			;;
		r)
			local answer
			menu_read answer "Discard all unapplied edits? [y/N] "
			if [[ "$answer" =~ ^[yY] ]]; then
				# shellcheck disable=SC2004 # CONF is associative (config.sh); $key is required, not arithmetic noise
				for key in "${!MENU_OLD_CONF[@]}"; do CONF[$key]="${MENU_OLD_CONF[$key]}"; done
				MENU_DIRTY=0
				menu_draft_delete
			fi
			;;
		s) menu_save_to_file_screen ;;
		l) menu_load_from_file_screen ;;
		b)
			if [[ "$MENU_BACK_ENABLED" == "1" ]]; then
				return 20
			fi
			echo "  unclear choice: $choice" >&2
			;;
		q) menu_quit_confirm && {
			menu_close_input
			exit 0
		} ;;
		*)
			local idx=0
			[[ "$choice" =~ ^[0-9]+$ ]] && idx=$((10#$choice))
			if [[ "$choice" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "${#MENU_GROUPS[@]}" ]]; then
				menu_section_screen "${MENU_GROUPS[$((idx - 1))]}"
			elif [[ "$choice" == "$((${#MENU_GROUPS[@]} + 1))" ]]; then
				menu_panel_password_screen
			else
				echo "  unclear choice: $choice" >&2
			fi
			;;
		esac
	done
}

# menu_run_reconfigure - entry point for `install.sh reconfigure`
# without -y. Returns 0 once the user chose "Apply".
menu_run_reconfigure() {
	menu_open_input
	for key in "${!CONF[@]}"; do MENU_OLD_CONF[$key]="${CONF[$key]}"; done
	menu_reconfigure_screen
	local rc=$?
	menu_draft_delete
	menu_close_input
	return "$rc"
}

# ------------------------------------------------------------------
# Management menu (tech.md 5.2): `dpistack` with an installed config.
# Each action runs in a subshell, so its lock and `exit` calls end with
# the action and the menu carries on.
# ------------------------------------------------------------------

# shellcheck disable=SC2034 # read by menu_reconfigure_screen
MENU_BACK_ENABLED=0
MANAGE_COMPONENTS=(suricata evebox ntopng redis panel victoriametrics prometheus node_exporter grafana)

# manage_ctl - the installed dpistack, or the install.sh next to this file
# when run from a clone (the verbs are the same).
manage_ctl() {
	# DPISTACK_BIN names another program that answers the verbs (tests).
	if [[ -n "${DPISTACK_BIN:-}" && -x "$DPISTACK_BIN" ]]; then
		echo "$DPISTACK_BIN"
		return 0
	fi
	if [[ -x "$(path_ctl_bin)" ]]; then
		path_ctl_bin
	elif [[ -x "$SCRIPT_DIR/install.sh" ]]; then
		echo "$SCRIPT_DIR/install.sh"
	else
		return 1
	fi
}

# menu_manage_ctl <args...> - runs a dpistack verb; an absent or failing
# helper prints the reason and leaves the menu running.
menu_manage_ctl() {
	local ctl rc
	if ! ctl=$(manage_ctl); then
		echo "  dpistack not found, check the installation (the selfinstall step)" >&2
		return 1
	fi
	"$ctl" "$@"
	rc=$?
	((rc == 0)) || echo "  dpistack returned code $rc" >&2
	return "$rc"
}

menu_manage_summary() {
	local ctl out active total health="no data"
	if ctl=$(manage_ctl) && out=$("$ctl" status --json 2>/dev/null) && command -v jq >/dev/null 2>&1; then
		total=$(jq '[.components[] | select(.state != "absent")] | length' <<<"$out" 2>/dev/null)
		active=$(jq '[.components[] | select(.state == "active")] | length' <<<"$out" 2>/dev/null)
		printf 'components: %s of %s active' "${active:-?}" "${total:-?}"
	else
		printf 'components: no data'
	fi
	if [[ -f "$(path_health_json)" ]] && command -v jq >/dev/null 2>&1; then
		health=$(jq -r '.overall // "no data"' "$(path_health_json)" 2>/dev/null)
	fi
	printf '  |  health: %s' "$health"
}

menu_manage_logs() {
	local i=1 id choice
	for id in "${MANAGE_COMPONENTS[@]}"; do
		printf '  %d) %s\n' "$i" "$id" >&2
		i=$((i + 1))
	done
	menu_read choice "Component (number, Enter - back): "
	menu_die_on_eof
	[[ "$choice" =~ ^[0-9]+$ ]] || return 0
	((10#$choice >= 1 && 10#$choice <= ${#MANAGE_COMPONENTS[@]})) || {
		echo "  no such number" >&2
		return 0
	}
	id="${MANAGE_COMPONENTS[$((10#$choice - 1))]}"
	menu_manage_ctl logs "$id" -n 200
	menu_read choice "f - follow the log (Ctrl+C - exit), Enter - back: "
	if [[ "$choice" == "f" ]]; then
		# A no-op handler, not "ignore": the child keeps the default
		# Ctrl+C and stops, the menu itself stays.
		trap 'true' INT
		menu_manage_ctl logs "$id" -n 200 --follow
		trap 'menu_on_interrupt' INT
	fi
}

menu_manage_tests() {
	local ctl out rc
	ctl=$(manage_ctl) || {
		echo "  dpistack not found, check the installation (the selfinstall step)" >&2
		return 1
	}
	out=$("$ctl" test all --json 2>&1)
	rc=$?
	if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$out"; then
		jq -r '.[] | "  \(.name): \(.status) (\(.duration_ms) ms) - \(.detail)"' <<<"$out"
	else
		printf '%s\n' "$out" >&2
	fi
	((rc == 0)) || echo "  some tests failed (code $rc)" >&2
}

menu_manage_password() {
	local p1 p2 ctl
	menu_read_secret p1 "New panel password: "
	menu_die_on_eof
	[[ -n "$p1" ]] || {
		echo "  an empty password is not accepted" >&2
		return 0
	}
	menu_read_secret p2 "Repeat the password: "
	if [[ "$p1" != "$p2" ]]; then
		echo "  the passwords do not match, nothing changed" >&2
		return 0
	fi
	ctl=$(manage_ctl) || {
		echo "  dpistack not found, check the installation (the selfinstall step)" >&2
		return 1
	}
	printf '%s\n' "$p1" | "$ctl" panel-passwd
}

# menu_manage_uninstall - returns 0 only when the stack was removed.
menu_manage_uninstall() {
	local word mode
	menu_read word "Type the word \"remove\" to confirm (Enter = cancel): "
	menu_die_on_eof
	if [[ "$word" != "remove" ]]; then
		echo "  cancelled" >&2
		return 1
	fi
	echo "  1) normal removal   2) removal with data (--purge)" >&2
	menu_read mode "> "
	case "$mode" in
	1) (cmd_uninstall) ;;
	2) (PURGE=1 cmd_uninstall) ;;
	*)
		echo "  cancelled" >&2
		return 1
		;;
	esac
}

menu_run_manage() {
	menu_open_input
	local choice rc answer
	while true; do
		echo >&2
		echo "$(menu_bold "dpistack v${DPISTACK_VERSION}")  |  Managing the installed stand" >&2
		echo "Config: $(path_conf)  |  $(menu_manage_summary)" >&2
		echo >&2
		echo "  1) Configure                     config sections, diff, apply" >&2
		echo "  2) Component status" >&2
		echo "  3) Logs" >&2
		echo "  4) Run tests" >&2
		echo "  5) Upgrade packages" >&2
		echo "  6) Uninstall" >&2
		echo "  7) Panel password" >&2
		echo >&2
		echo "  q) Quit" >&2
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		1)
			(
				MENU_BACK_ENABLED=1
				cmd_reconfigure
			)
			rc=$?
			((rc == 0)) || echo "  configuration finished with code $rc" >&2
			;;
		2) menu_manage_ctl status ;;
		3) menu_manage_logs ;;
		4) menu_confirm "Run the check tests?" && menu_manage_tests ;;
		5)
			menu_read answer "Upgrade packages? [y/N] "
			if [[ "$answer" =~ ^[yY] ]]; then
				(cmd_upgrade) || echo "  upgrade failed" >&2
			fi
			;;
		6)
			if menu_manage_uninstall; then
				menu_close_input
				return 0
			fi
			;;
		7) menu_confirm "Change the panel password?" && menu_manage_password ;;
		q | Q)
			menu_close_input
			return 0
			;;
		*) echo "  unclear choice: $choice" >&2 ;;
		esac
	done
}
