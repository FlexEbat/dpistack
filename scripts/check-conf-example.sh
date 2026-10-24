#!/usr/bin/env bash
# Slice 25, criterion 5: every key in dpistack.conf.example is in the
# tech.md 4.3 table, and the other way round. Secrets (the "secret" rows)
# are not dpistack.conf keys and must not appear in the example. Also
# checks that each key's example value equals the default in lib/schema.sh,
# so the example can't drift from what the installer really does.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 1

example=dpistack.conf.example
techmd=tech.md
status=0

# Keys of the 4.3 table: backticked UPPER_CASE names in the first column,
# from the table header to the "Load-time checks" line.
bt=$(printf '\140')
tech_keys=$(awk '
	/^### 4\.3 /          { in43 = 1; next }
	in43 && /^Load-time checks/ { exit }
	in43 && /^\| `/        { print }
' "$techmd" | sed -E 's/^\| ([^|]*)\|.*/\1/' | grep -v "^secret" |
	grep -oE "${bt}[A-Z][A-Z0-9_]+${bt}" | tr -d "$bt" | sort -u)

example_keys=$(grep -E '^[A-Z][A-Z0-9_]*=' "$example" | cut -d= -f1 | sort -u)

if [[ -z "$tech_keys" ]]; then
	echo "no keys found in the $techmd 4.3 table"
	exit 1
fi

only_example=$(comm -13 <(echo "$tech_keys") <(echo "$example_keys"))
only_tech=$(comm -23 <(echo "$tech_keys") <(echo "$example_keys"))

if [[ -n "$only_example" ]]; then
	echo "in $example but not in tech.md 4.3:"
	mapfile -t lines <<<"$only_example"
	printf '  %s\n' "${lines[@]}"
	status=1
fi
if [[ -n "$only_tech" ]]; then
	echo "in tech.md 4.3 but not in $example:"
	mapfile -t lines <<<"$only_tech"
	printf '  %s\n' "${lines[@]}"
	status=1
fi

# Defaults: the example must say what lib/schema.sh says. Keys whose
# default is computed at run time are empty in the schema and in the example.
# shellcheck source=lib/schema.sh
source lib/schema.sh
while IFS='=' read -r key value; do
	[[ -n "${SCHEMA_TYPE[$key]+x}" ]] || continue
	if [[ "$value" != "${SCHEMA_DEFAULT[$key]}" ]]; then
		echo "default differs for $key: example '$value', schema '${SCHEMA_DEFAULT[$key]}'"
		status=1
	fi
done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$example")

# A schema key that is neither a secret nor in the example is a gap too.
for key in "${SCHEMA_KEYS[@]}"; do
	[[ "${SCHEMA_SECRET[$key]}" == "yes" ]] && continue
	grep -q "^$key=" "$example" || {
		echo "schema key $key is missing from $example"
		status=1
	}
done

[[ $status -eq 0 ]] && echo "ok: $(echo "$example_keys" | wc -l) keys match tech.md 4.3 and lib/schema.sh"
exit $status
