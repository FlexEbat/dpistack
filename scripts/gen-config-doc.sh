#!/usr/bin/env bash
# Writes docs/configuration.md (English) and docs/configuration.ru.md (Russian)
# from the schema (lib/schema.sh), the hint table of the Settings screen
# (panel/web/modules/settings-model.js) and scripts/config-hints.ru, so the
# reference cannot drift from the program. `--check` compares instead of
# writing and exits 1 when a file is out of date or a key lacks a hint.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/schema.sh
source "$REPO_DIR/lib/schema.sh"

declare -A HINT_EN HINT_RU TITLE_EN TITLE_RU
while IFS= read -r line; do
	HINT_EN[${line%%|*}]="${line#*|}"
done < <(sed -n 's/^  \([A-Z][A-Z0-9_]*\): "\(.*\)",$/\1|\2/p' "$REPO_DIR/panel/web/modules/settings-model.js")
while IFS= read -r line; do
	TITLE_EN[${line%%|*}]="${line#*|}"
done < <(sed -n 's/^  \["\([a-z]*\)", "\(.*\)"\],$/\1|\2/p' "$REPO_DIR/panel/web/modules/settings-model.js")
while IFS= read -r line; do
	[[ "$line" == \#* || -z "$line" ]] && continue
	key="${line%%|*}"
	if [[ "$key" == group:* ]]; then
		TITLE_RU[${key#group:}]="${line#*|}"
	else
		HINT_RU[$key]="${line#*|}"
	fi
done <"$REPO_DIR/scripts/config-hints.ru"

# render <en|ru>: the whole document on stdout.
render() {
	local lang=$1
	if [[ "$lang" == "en" ]]; then
		cat <<'HEAD'
# Settings reference

English | [Русский](configuration.ru.md)

The file `/etc/dpistack/dpistack.conf` (`KEY=VALUE` format, one line per key). Secrets live apart, in `/etc/dpistack/secrets.conf` (mode 0600), and are shown nowhere: the panel and `dpistack settings list` print only "set" or "not set".

You can change settings in three ways: the Settings screen of the panel, `dpistack settings set` and `dpistack reconfigure`. The "Change" column says what a change costs: a **light** one applies at once (the config is rendered again and the affected service restarts), a **heavy** one starts an install or a rebuild of a component and runs as a separate job.

The file is made by `scripts/gen-config-doc.sh` from the key schema; do not edit it by hand.

HEAD
	else
		cat <<'HEAD'
# Справочник параметров

[English](configuration.md) | Русский

Файл `/etc/dpistack/dpistack.conf` (формат `KEY=VALUE`, по строке на ключ). Секреты лежат отдельно, в `/etc/dpistack/secrets.conf` (права 0600), и не показываются нигде: панель и `dpistack settings list` пишут только «задан» или «не задан».

Менять параметры можно тремя способами: экран «Настройки» панели, `dpistack settings set` и `dpistack reconfigure`. Столбец «Изменение» говорит, чем оно обходится: **лёгкое** применяется сразу (перерисовка конфигурации и перезапуск затронутой службы), **тяжёлое** запускает установку или пересборку компонента и идёт отдельной задачей.

Файл создаётся скриптом `scripts/gen-config-doc.sh` из схемы ключей; править его руками не нужно.

HEAD
	fi
	local g title key values default weight desc head w_int w_str w_empty w_heavy w_light w_secret w_adv
	if [[ "$lang" == "en" ]]; then
		head='| Key | Values | Default | Change | Description |'
		w_int="integer" w_str="string" w_empty="empty" w_heavy="heavy" w_light="light" w_secret="secret" w_adv="advanced"
	else
		head='| Ключ | Значения | По умолчанию | Изменение | Описание |'
		w_int="целое" w_str="строка" w_empty="пусто" w_heavy="тяжёлое" w_light="лёгкое" w_secret="секрет" w_adv="расширенный"
	fi
	for g in capture components eve rules access metrics watch tests; do
		if [[ "$lang" == "en" ]]; then title="${TITLE_EN[$g]:-}"; else title="${TITLE_RU[$g]:-}"; fi
		printf '## %s\n\n%s\n| --- | --- | --- | --- | --- |\n' "$title" "$head"
		for key in "${SCHEMA_KEYS[@]}"; do
			[[ "${SCHEMA_GROUP[$key]}" == "$g" ]] || continue
			case "${SCHEMA_TYPE[$key]}" in
			enum) values="${SCHEMA_OPTIONS[$key]//,/ \\| }" ;;
			int) values="$w_int ${SCHEMA_OPTIONS[$key]}" ;;
			*) values="$w_str" ;;
			esac
			default="${SCHEMA_DEFAULT[$key]}"
			[[ -n "$default" ]] && default="\`$default\`" || default="$w_empty"
			[[ "${SCHEMA_WEIGHT[$key]}" == "heavy" ]] && weight="$w_heavy" || weight="$w_light"
			if [[ "$lang" == "en" ]]; then desc="${HINT_EN[$key]:-}"; else desc="${HINT_RU[$key]:-}"; fi
			[[ "${SCHEMA_SECRET[$key]}" == "yes" ]] && values="$w_secret"
			[[ "${SCHEMA_LEVEL[$key]}" == "advanced" ]] && desc="$desc ($w_adv)"
			printf '| %s | %s | %s | %s | %s |\n' "\`$key\`" "$values" "$default" "$weight" "$desc"
		done
		echo
	done
}

# missing_hints: every schema key needs an English and a Russian hint.
missing_hints() {
	local key bad=0
	for key in "${SCHEMA_KEYS[@]}"; do
		[[ -n "${HINT_EN[$key]:-}" ]] || {
			echo "no English hint for $key (settings-model.js)" >&2
			bad=1
		}
		[[ -n "${HINT_RU[$key]:-}" ]] || {
			echo "no Russian hint for $key (scripts/config-hints.ru)" >&2
			bad=1
		}
	done
	return $bad
}

missing_hints || exit 1
if [[ "${1:-}" == "--check" ]]; then
	rc=0
	for pair in "en:configuration.md" "ru:configuration.ru.md"; do
		if ! render "${pair%%:*}" | diff -q - "$REPO_DIR/docs/${pair#*:}" >/dev/null; then
			echo "docs/${pair#*:} is out of date: run scripts/gen-config-doc.sh" >&2
			rc=1
		fi
	done
	exit $rc
fi
render en >"$REPO_DIR/docs/configuration.md"
render ru >"$REPO_DIR/docs/configuration.ru.md"
