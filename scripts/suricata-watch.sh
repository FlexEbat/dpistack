#!/usr/bin/env bash
# The automatic check of Suricata releases (run weekly by
# .github/workflows/suricata-watch.yml):
#  1. the pinned SURICATA_STABLE_REF must still build (drift of Rust,
#     nDPI or the runner image shows up here first);
#  2. a newer stable release of the same series is built, and the result
#     goes to an issue: "tested, raise the pin" or "does not build";
#  3. a newer series (for example 9.0) is announced once.
# It never changes the repository; raising the pin is a normal change that
# goes through the gate. Issues are not duplicated: one open issue per title.
# Exit status 1 only when the pinned release itself fails.
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="${SURICATA_RELEASE_CHECK:-$repo_dir/scripts/check-suricata-release.sh}"
build="${SURICATA_BUILD_CHECK:-$repo_dir/scripts/suricata-build-check.sh}"
gh_cmd="${GH:-gh}"

declare -A rel=()
info="$(bash "$check")" || true
while IFS='=' read -r key value; do
	[[ -n "$key" ]] && rel[$key]="$value"
done <<<"$info"

status="${rel[status]:-unknown}"
current="${rel[current]:-}"
latest="${rel[latest]:-}"
newer_series="${rel[newer_series]:-}"

if [[ "$status" == "unknown" ]]; then
	echo "suricata-watch: the release check gave no answer" >&2
	exit 1
fi

run_url=""
if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
	run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID}"
fi

# issue <title> <body> - one open issue per title.
issue() {
	local title="$1" body="$2" open
	open="$("$gh_cmd" issue list --state open --search "\"$title\" in:title" --json title \
		--jq "[.[] | select(.title == \"$title\")] | length" 2>/dev/null)" || open=0
	if [[ "${open:-0}" == "0" ]]; then
		"$gh_cmd" issue create --title "$title" --body "$body${run_url:+

Прогон: $run_url}"
	else
		echo "suricata-watch: issue \"$title\" is already open"
	fi
}

result=0

echo "== pinned release: $current"
if ! bash "$build" "$current"; then
	issue "Suricata $current (SURICATA_STABLE_REF) больше не собирается" \
		"Закреплённый релиз не прошёл проверку сборки с nDPI и плагином. Возможные причины: изменился Rust или образ раннера, nDPI, зависимости. Нужно разобраться до следующего релиза."
	result=1
fi

if [[ "$status" == "update" && -n "$latest" ]]; then
	echo "== newer release of the same series: $latest"
	if bash "$build" "$latest"; then
		issue "Suricata $latest проверен: поднять SURICATA_STABLE_REF" \
			"Новый релиз $latest собирается с nDPI и плагином и загружает конфигурацию установщика. Чтобы принять: поменять SURICATA_STABLE_REF в lib/step_suricata.sh на $latest, обновить версию в tech.md и пройти обычный путь dev, гейт, PR в main."
	else
		issue "Suricata $latest не прошёл проверку сборки" \
			"Новый релиз $latest не собрался с nDPI и плагином или не загрузил конфигурацию. SURICATA_STABLE_REF остаётся $current. Нужно понять, что изменилось (минимальный Rust, API плагина nDPI), и поправить установщик."
	fi
fi

if [[ -n "$newer_series" ]]; then
	issue "Вышла новая серия Suricata: $newer_series" \
		"Стабильная серия $newer_series новее закреплённой ($current). Переход на серию это отдельное решение: нужны проверка плагина nDPI, COPR OISF и PPA соответствующей серии. SURICATA_COPR в lib/os.sh привязан к серии."
fi

exit "$result"
