#!/usr/bin/env bash
# Template rendering (tech.md section 3: "подстановка @@KEY@@ и блоков
# в templates/"). One implementation for every step, instead of a
# private awk in each step file.
#
#   render_template <template-file> [KEY=VALUE ...]
#
# - inline: every @@KEY@@ inside a line is replaced by VALUE;
# - block: a line that is exactly @@KEY@@ is replaced by VALUE, which
#   may span several lines; an empty VALUE drops the line entirely;
# - a placeholder with no matching KEY is an error (typos fail loudly
#   instead of leaking "@@..@@" into a config).
# VALUE is taken literally: no escape processing, '&' is not special.

render_template() {
	local tpl="$1"
	shift
	[[ -r "$tpl" ]] || {
		echo "render: шаблон не найден: $tpl" >&2
		return 1
	}

	local -a keys=() values=()
	local kv
	for kv in "$@"; do
		keys+=("${kv%%=*}")
		values+=("${kv#*=}")
	done

	# bash 5.2 treats '&' in a ${var//pat/rep} replacement as the match
	# unless this is off; older bash has no such option.
	shopt -u patsub_replacement 2>/dev/null || true

	local line i key found rc=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ ^@@([A-Z0-9_]+)@@$ ]]; then
			key="${BASH_REMATCH[1]}"
			found=0
			for i in "${!keys[@]}"; do
				if [[ "${keys[$i]}" == "$key" ]]; then
					[[ -n "${values[$i]}" ]] && printf '%s\n' "${values[$i]}"
					found=1
					break
				fi
			done
			if ((!found)); then
				echo "render: нет значения для блока @@${key}@@ в $tpl" >&2
				rc=1
			fi
			continue
		fi

		for i in "${!keys[@]}"; do
			line="${line//@@${keys[$i]}@@/${values[$i]}}"
		done
		if [[ "$line" =~ @@[A-Z0-9_]+@@ ]]; then
			echo "render: нет значения для ${BASH_REMATCH[0]} в $tpl" >&2
			rc=1
		fi
		printf '%s\n' "$line"
	done <"$tpl"
	return "$rc"
}
