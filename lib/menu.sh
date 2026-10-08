#!/usr/bin/env bash
# Plain-Bash text menu for `install`/`reconfigure` (tech.md 5.0, 5.1,
# 5.3). No dialog/whiptail/ncurses/cursor codes: every screen is just
# printed again, so it works over SSH, in tmux, and stays in scrollback.

MENU_GROUPS=(capture components eve rules access metrics watch tests)
declare -A MENU_GROUP_TITLE=(
	[capture]="Захват и режим"
	[components]="Компоненты и источники"
	[eve]="EVE и хранение"
	[rules]="Правила"
	[access]="Доступ"
	[metrics]="Метрики"
	[watch]="Наблюдение и оповещения"
	[tests]="Тесты"
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
	exec 8<"${DPISTACK_INPUT:-/dev/tty}"
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
	echo "прервано, ничего не изменено" >&2
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
		echo "конец ввода, выхожу без применения" >&2
		menu_close_input
		exit 2
	fi
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
	panel_auth_write "$plaintext" || die 1 "не удалось записать хэш пароля панели (argon2)"
	MENU_PANEL_PASSWORD=""
}

menu_draft_save() {
	local key
	{
		for key in $(printf '%s\n' "${!CONF[@]}" | sort); do
			printf '%s=%s\n' "$key" "${CONF[$key]}"
		done
	} | atomic_write "$(path_conf_draft)"
	chmod 0600 "$(path_conf_draft)"
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
	components) echo "Suricata: ${CONF[SURICATA_SOURCE]}, nDPI: $([[ ${CONF[NDPI_ENABLE]} == yes ]] && echo да || echo нет)" ;;
	eve)
		local n
		n=$(tr ',' '\n' <<<"${CONF[EVE_TYPES]}" | grep -c .)
		echo "$n типов, ротация ${CONF[EVE_ROTATE]}"
		;;
	rules) echo "${CONF[RULES_SOURCES]}, ${CONF[RULES_UPDATE_CALENDAR]}" ;;
	access) echo "${CONF[ACCESS_MODE]}" ;;
	metrics) echo "экспорт: $([[ ${CONF[METRICS_EXPORT]} == yes ]] && echo да || echo нет), бэкенд: ${CONF[METRICS_BACKEND]}" ;;
	watch) echo "${CONF[ALERT_CHANNELS]}" ;;
	tests) echo "после установки: $([[ ${CONF[TEST_ON_INSTALL]} == yes ]] && echo да || echo нет)" ;;
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
		echo "$key (сейчас: ${current:-<пусто>}, умолчание: ${SCHEMA_DEFAULT[$key]:-<пусто>})" >&2
		[[ -n "$opts" ]] && echo "  варианты: $opts" >&2
		local answer
		if schema_is_secret "$key"; then
			menu_read_secret answer "Новое значение (Enter - оставить, - сброс, ? подсказка): "
		else
			menu_read answer "Новое значение (Enter - оставить, - сброс, ? подсказка): "
		fi
		menu_die_on_eof
		case "$answer" in
		"") return 0 ;;
		"?")
			echo "  ${key}: группа ${SCHEMA_GROUP[$key]}, тип ${SCHEMA_TYPE[$key]}" >&2
			continue
			;;
		"-")
			config_set_kv "$key" "${SCHEMA_DEFAULT[$key]}"
			menu_draft_save
			return 0
			;;
		*)
			local err
			if err=$(schema_validate_one "$key" "$answer"); then
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
				shown=$([[ -n "${SECRETS[$key]:-}" ]] && echo задан || echo "не задан")
			else
				shown="${CONF[$key]:-}"
			fi
			printf '  %2d) %-28s = %s %s\n' "$i" "$key" "$shown" "$mark" >&2
			i=$((i + 1))
		done
		echo "  a) $([[ $MENU_SHOW_ADVANCED == 1 ]] && echo "скрыть" || echo "показать") advanced   0) назад   ?) справка   q) выйти" >&2
		local problems
		problems=$(menu_problems_count)
		if [[ "$problems" -gt 0 ]]; then
			menu_red "Проблем: $problems" >&2
			echo >&2
		else
			echo "Проблем: $problems" >&2
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
			echo "  Номер - править ключ; Enter/0 - назад; a - показать/скрыть advanced." >&2
			continue
			;;
		*)
			if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#keys[@]})); then
				menu_edit_key "${keys[$((choice - 1))]}"
			else
				echo "  непонятный пункт: $choice" >&2
			fi
			;;
		esac
	done
}

menu_quit_confirm() {
	[[ "$MENU_DIRTY" != "1" ]] && return 0
	local answer
	menu_read answer "Есть неприменённые правки. Выйти без применения? [y/N] "
	[[ "$answer" =~ ^[yYдД] ]]
}

menu_panel_password_screen() {
	while true; do
		local p1 p2
		menu_read_secret p1 "Пароль панели: "
		menu_die_on_eof
		if [[ -z "$p1" ]]; then
			echo "  пустой пароль не принимается" >&2
			continue
		fi
		menu_read_secret p2 "Повторите пароль: "
		if [[ "$p1" != "$p2" ]]; then
			echo "  пароли не совпадают" >&2
			continue
		fi
		MENU_PANEL_PASSWORD="$p1"
		MENU_PANEL_PASSWORD_SET=1
		MENU_DIRTY=1
		return 0
	done
}

# menu_quick_install - 5.1 "Быстрая установка": interfaces (ip -o link,
# no lo, default-route one marked), Suricata source, access mode, panel
# password; everything else keeps its default.
menu_quick_install() {
	echo >&2
	menu_bold "Быстрая установка" >&2
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
		[[ "$name" == "$default_iface" ]] && tag=" (маршрут по умолчанию)"
		echo "  $i) $name$tag" >&2
		i=$((i + 1))
	done
	local sel
	menu_read sel "Интерфейсы (номера через запятую): "
	local -a chosen=()
	local n
	IFS=',' read -ra sel_nums <<<"$sel"
	for n in "${sel_nums[@]}"; do
		n="${n// /}"
		[[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#ifaces[@]})) && chosen+=("${ifaces[$((n - 1))]}")
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
	menu_read src "Способ Suricata [source/oisf/distro, Enter=${CONF[SURICATA_SOURCE]}]: "
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
	menu_read mode "Режим доступа [localhost/lan/nginx, Enter=${CONF[ACCESS_MODE]}]: "
	if [[ -n "$mode" ]]; then
		local err2
		if err2=$(schema_validate_one ACCESS_MODE "$mode"); then
			config_set_kv ACCESS_MODE "$mode"
			MENU_DIRTY=1
		else
			echo "  $err2" >&2
		fi
	fi

	menu_panel_password_screen
	menu_draft_save
}

menu_check_system_screen() {
	local reasons
	reasons=$(step_preflight_reasons)
	echo >&2
	if [[ -z "$reasons" ]]; then
		echo "preflight: без замечаний" >&2
	else
		echo "preflight:" >&2
		echo "  ${reasons//$'\n'/$'\n  '}" >&2
	fi
	local _enter
	menu_read _enter "Enter для продолжения"
}

menu_plan_screen() {
	echo >&2
	run_plan >&2
	local _enter
	menu_read _enter "Enter для продолжения"
}

menu_save_to_file_screen() {
	local path
	menu_read path "Путь к файлу: "
	[[ -z "$path" ]] && return 0
	config_write_conf "$path"
	echo "  сохранено в $path" >&2
}

menu_load_from_file_screen() {
	local path
	menu_read path "Путь к файлу: "
	[[ -z "$path" || ! -f "$path" ]] && {
		echo "  файл не найден" >&2
		return 0
	}
	config_load_kv_file "$path"
	local errs
	errs=$(config_validate)
	if [[ -n "$errs" ]]; then
		echo "  в загруженном файле есть ошибки:" >&2
		echo "  $errs" >&2
	fi
	MENU_DIRTY=1
	menu_draft_save
}

# menu_main_screen -> 0 (user chose "Установить") or exits the process.
menu_main_screen() {
	while true; do
		echo >&2
		echo "$(menu_bold "dpistack v${DPISTACK_VERSION}") | $OS_ID ${OS_VERSION_ID:-}, $(uname -m) | systemd: $(command -v systemctl >/dev/null && echo да || echo нет)" >&2
		echo "Установка. Конфиг: $(path_conf) (не создан)" >&2
		echo >&2
		echo "  1) Быстрая установка" >&2
		local i=2 g
		for g in "${MENU_GROUPS[@]}"; do
			printf '  %2d) %-30s %s\n' "$i" "${MENU_GROUP_TITLE[$g]}" "$(menu_group_summary "$g")" >&2
			i=$((i + 1))
		done
		printf '  %2d) %-30s %s\n' "$i" "Пароль панели" "$([[ $MENU_PANEL_PASSWORD_SET == 1 ]] && echo "задан" || echo "не задан")" >&2
		echo >&2
		echo "  c) Проверить систему   p) План   s) Сохранить в файл   l) Загрузить из файла" >&2
		echo "  i) Установить          q) Выйти" >&2
		local problems
		problems=$(menu_problems_count)
		echo >&2
		if [[ "$problems" -gt 0 ]]; then
			menu_red "Проблемы ($problems): $(menu_problems | head -1)" >&2
			echo >&2
		else
			echo "Проблемы ($problems)" >&2
		fi
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		1) menu_quick_install ;;
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
				echo "  нельзя установить, пока есть проблемы" >&2
				continue
			fi
			if [[ "$MENU_PANEL_PASSWORD_SET" != "1" ]]; then
				echo "  без пароля панели установка недоступна" >&2
				continue
			fi
			return 0
			;;
		*)
			local idx=$((10#${choice:-0} - 1))
			if [[ "$choice" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "${#MENU_GROUPS[@]}" ]]; then
				menu_section_screen "${MENU_GROUPS[$((idx - 1))]}"
			elif [[ "$choice" == "$((${#MENU_GROUPS[@]} + 2))" ]]; then
				menu_panel_password_screen
			else
				echo "  непонятный пункт: $choice" >&2
			fi
			;;
		esac
	done
}

menu_found_install_screen() {
	while true; do
		echo >&2
		menu_bold "dpistack v${DPISTACK_VERSION} | Найдена установка" >&2
		echo >&2
		echo "  1) Настроить   2) Применить текущий конфиг заново   3) Меню управления   4) Выйти" >&2
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		1) return 10 ;; # caller switches to the reconfigure menu
		2) return 11 ;; # idempotent re-apply, no questions
		3)
			echo "  меню управления появится в слайсе 15, пока недоступно" >&2
			continue
			;;
		4 | q)
			menu_close_input
			exit 0
			;;
		*) echo "  непонятный пункт: $choice" >&2 ;;
		esac
	done
}

# menu_run_install - entry point for `install.sh install` without -y.
# Returns 0 once the user chose "Установить"; the caller continues
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
		# rc=10 (настроить) falls through to the reconfigure menu below.
	elif [[ -f "$(path_conf_draft)" ]]; then
		local answer
		menu_read answer "Продолжить черновик? [Y/n] "
		if [[ "$answer" =~ ^[nNнН] ]]; then
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
		echo "  изменений нет" >&2
		return 1
	fi

	if [[ "$CONFIG_CHANGE_WEIGHT" == "heavy" ]]; then
		echo "  Тяжёлые изменения затронут шаги: ${CONFIG_AFFECTED_STEPS[*]}" >&2
		local answer
		menu_read answer "  Продолжить? [y/N] "
		menu_die_on_eof
		if [[ ! "$answer" =~ ^[yYдД] ]]; then
			echo "  отменено" >&2
			return 1
		fi
	fi

	local step
	for step in "${CONFIG_AFFECTED_STEPS[@]}"; do
		if [[ "$step" == "suricata" ]]; then
			if ! suricata_validate_render "$(suricata_render_yaml)"; then
				echo "  suricata -T упал на новом suricata.yaml, правки остаются в меню (см. вывод выше)" >&2
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
	menu_read _enter "Enter для продолжения"
}

# menu_reconfigure_screen - 5.3's section screen. `0) Назад` only makes
# sense when opened from the control menu (not built until slice 15),
# so a direct `dpistack reconfigure` behaves like `q` there, per spec.
menu_reconfigure_screen() {
	while true; do
		echo >&2
		menu_bold "dpistack v${DPISTACK_VERSION}" >&2
		echo " | Настройка существующей установки" >&2
		echo "Конфиг: $(path_conf)" >&2
		echo >&2
		local i=1 g
		for g in "${MENU_GROUPS[@]}"; do
			printf '  %2d) %-30s %s\n' "$i" "${MENU_GROUP_TITLE[$g]}" "$(menu_group_summary "$g")" >&2
			i=$((i + 1))
		done
		printf '  %2d) %-30s %s\n' "$i" "Пароль панели" "сменить" >&2
		echo >&2
		echo "  d) Изменения (diff)   a) Применить   r) Отменить правки" >&2
		echo "  s) Сохранить в файл   l) Загрузить из файла   q) Выйти" >&2
		local changed=0 key
		for key in "${!CONF[@]}"; do
			[[ "${CONF[$key]}" != "${MENU_OLD_CONF[$key]:-}" ]] && changed=$((changed + 1))
		done
		local rc_problems
		rc_problems=$(menu_problems_count)
		if [[ "$rc_problems" -gt 0 ]]; then
			echo "Правки: $changed ключ(ей). $(menu_red "Проблемы: $rc_problems")" >&2
		else
			echo "Правки: $changed ключ(ей). Проблемы: $rc_problems" >&2
		fi
		local choice
		menu_read choice "> "
		menu_die_on_eof
		case "$choice" in
		d) menu_diff_screen ;;
		a)
			if menu_reconfigure_confirm_and_validate; then
				return 0 # caller writes config.sh and applies the affected steps
			fi
			;;
		r)
			local answer
			menu_read answer "Сбросить все неприменённые правки? [y/N] "
			if [[ "$answer" =~ ^[yYдД] ]]; then
				# shellcheck disable=SC2004 # CONF is associative (config.sh); $key is required, not arithmetic noise
				for key in "${!MENU_OLD_CONF[@]}"; do CONF[$key]="${MENU_OLD_CONF[$key]}"; done
				MENU_DIRTY=0
				menu_draft_delete
			fi
			;;
		s) menu_save_to_file_screen ;;
		l) menu_load_from_file_screen ;;
		q) menu_quit_confirm && {
			menu_close_input
			exit 0
		} ;;
		*)
			local idx=$((10#${choice:-0}))
			if [[ "$choice" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "${#MENU_GROUPS[@]}" ]]; then
				menu_section_screen "${MENU_GROUPS[$((idx - 1))]}"
			elif [[ "$choice" == "$((${#MENU_GROUPS[@]} + 1))" ]]; then
				menu_panel_password_screen
			else
				echo "  непонятный пункт: $choice" >&2
			fi
			;;
		esac
	done
}

# menu_run_reconfigure - entry point for `install.sh reconfigure`
# without -y. Returns 0 once the user chose "Применить".
menu_run_reconfigure() {
	menu_open_input
	for key in "${!CONF[@]}"; do MENU_OLD_CONF[$key]="${CONF[$key]}"; done
	menu_reconfigure_screen
	menu_draft_delete
	menu_close_input
	return 0
}
