#!/usr/bin/env bats
# The documentation set: present, current and free of broken links and of
# leftover "not tested" remarks.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "the contributor files exist and name the gate" {
	[ -s "$REPO_DIR/AGENTS.md" ]
	[ -s "$REPO_DIR/CONTRIBUTING.md" ]
	grep -q 'scripts/gate.sh' "$REPO_DIR/AGENTS.md"
	grep -q 'scripts/gate.sh' "$REPO_DIR/CONTRIBUTING.md"
	grep -q 'scripts/bundle.sh' "$REPO_DIR/AGENTS.md"
}

@test "docs/configuration.md is what the generator makes from the schema" {
	run bash "$REPO_DIR/scripts/gen-config-doc.sh" --check
	[ "$status" -eq 0 ]
}

@test "every key of dpistack.conf.example is described in docs/configuration.md" {
	while IFS= read -r key; do
		grep -q "^| \`$key\` |" "$REPO_DIR/docs/configuration.md" || {
			echo "not documented: $key"
			return 1
		}
	done < <(sed -n 's/^#\{0,1\}\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$REPO_DIR/dpistack.conf.example" | sort -u)
}

@test "every local link in the documents points to an existing file" {
	cd "$REPO_DIR"
	for doc in AGENTS.md CONTRIBUTING.md docs/*.md; do
		dir=$(dirname "$doc")
		while IFS= read -r target; do
			[ -e "$dir/$target" ] || {
				echo "$doc: broken link: $target"
				return 1
			}
		done < <(grep -oE '\]\([^)#:]+\)' "$doc" | sed -E 's/^\]\((.*)\)$/\1/')
	done
}

@test "the documents carry no remark that the software was not tried in real conditions" {
	cd "$REPO_DIR"
	run grep -rniE 'не проверен|на реальн(ом|ой|ых) (стенд|хост|систем)|проверено пока|only on stubs|untested|not tested' README.md AGENTS.md CONTRIBUTING.md docs
	[ "$status" -ne 0 ]
}
