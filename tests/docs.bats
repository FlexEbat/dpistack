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

@test "docs/configuration.md and docs/configuration.ru.md are what the generator makes from the schema" {
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

@test "the README and the guides come in English and in Russian; AGENTS, CONTRIBUTING, SECURITY and tech.md are English only" {
	cd "$REPO_DIR"
	for doc in README.md docs/*.md tests/data/README.md; do
		case "$doc" in *.ru.md) continue ;; esac
		[ -s "${doc%.md}.ru.md" ] || {
			echo "no Russian twin: $doc"
			return 1
		}
	done
	for doc in README.ru.md docs/*.ru.md tests/data/README.ru.md; do
		[ -s "${doc%.ru.md}.md" ] || {
			echo "no English twin: $doc"
			return 1
		}
	done
}

@test "each document links to its twin in the other language" {
	cd "$REPO_DIR"
	for doc in README docs/dashboard docs/deployment docs/installation docs/operations docs/platforms docs/troubleshooting docs/configuration; do
		grep -q "$(basename "$doc").ru.md" "$doc.md" || {
			echo "$doc.md does not link to its Russian twin"
			return 1
		}
		grep -q "$(basename "$doc").md" "$doc.ru.md" || {
			echo "$doc.ru.md does not link to its English twin"
			return 1
		}
	done
}

@test "every local link in the documents points to an existing file" {
	cd "$REPO_DIR"
	for doc in README.md README.ru.md AGENTS.md CONTRIBUTING.md SECURITY.md docs/*.md; do
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
	run grep -rniE 'не проверен|на реальн(ом|ой|ых) (стенд|хост|систем)|проверено пока|only on stubs|untested|not tested' README.md README.ru.md AGENTS.md CONTRIBUTING.md SECURITY.md docs
	[ "$status" -ne 0 ]
}
