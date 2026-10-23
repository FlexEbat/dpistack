#!/usr/bin/env bash
# Writes docs/configuration.md from the schema (lib/schema.sh) and the hint
# table of the settings screen (panel/web/modules/settings-model.js), so the
# reference cannot drift from the program. `--check` compares instead of
# writing and exits 1 when the file is out of date.
set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/schema.sh
source "$REPO_DIR/lib/schema.sh"

declare -A HINT
while IFS= read -r line; do
	key="${line%%|*}"
	HINT[$key]="${line#*|}"
done < <(sed -n 's/^  \([A-Z][A-Z0-9_]*\): "\(.*\)",$/\1|\2/p' "$REPO_DIR/panel/web/modules/settings-model.js")

group_title() {
	sed -n "s/^  \[\"$1\", \"\\(.*\\)\"\\],\$/\\1/p" "$REPO_DIR/panel/web/modules/settings-model.js"
}

render() {
	cat <<'HEAD'
# Справочник параметров

Файл `/etc/dpistack/dpistack.conf` (формат `KEY=VALUE`, по строке на ключ). Секреты лежат отдельно, в `/etc/dpistack/secrets.conf` (права 0600), и не показываются нигде: панель и `dpistack settings list` пишут только «задан» или «не задан».

Менять параметры можно тремя способами: экран «Настройки» панели, `dpistack settings set` и `dpistack reconfigure`. Столбец «Изменение» говорит, чем оно обходится: **лёгкое** применяется сразу (перерисовка конфигурации и перезапуск затронутой службы), **тяжёлое** запускает установку или пересборку компонента и идёт отдельной задачей.

Файл создаётся скриптом `scripts/gen-config-doc.sh` из схемы ключей; править его руками не нужно.

HEAD
	local g title key
	for g in capture components eve rules access metrics watch tests; do
		title=$(group_title "$g")
		printf '## %s\n\n| Ключ | Значения | По умолчанию | Изменение | Описание |\n| --- | --- | --- | --- | --- |\n' "$title"
		for key in "${SCHEMA_KEYS[@]}"; do
			[[ "${SCHEMA_GROUP[$key]}" == "$g" ]] || continue
			local values default weight desc
			case "${SCHEMA_TYPE[$key]}" in
			enum) values="${SCHEMA_OPTIONS[$key]//,/ \\| }" ;;
			int) values="целое ${SCHEMA_OPTIONS[$key]}" ;;
			*) values="строка" ;;
			esac
			default="${SCHEMA_DEFAULT[$key]}"
			[[ -n "$default" ]] && default="\`$default\`" || default="пусто"
			[[ "${SCHEMA_WEIGHT[$key]}" == "heavy" ]] && weight="тяжёлое" || weight="лёгкое"
			desc="${HINT[$key]:-}"
			[[ "${SCHEMA_SECRET[$key]}" == "yes" ]] && values="секрет"
			[[ "${SCHEMA_LEVEL[$key]}" == "advanced" ]] && desc="$desc (расширенный)"
			printf '| %s | %s | %s | %s | %s |\n' "\`$key\`" "$values" "$default" "$weight" "$desc"
		done
		echo
	done
}

if [[ "${1:-}" == "--check" ]]; then
	if render | diff -q - "$REPO_DIR/docs/configuration.md" >/dev/null; then
		exit 0
	fi
	echo "docs/configuration.md устарел: запустите scripts/gen-config-doc.sh" >&2
	exit 1
fi
render >"$REPO_DIR/docs/configuration.md"
