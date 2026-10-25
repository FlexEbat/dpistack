#!/usr/bin/env bats
# Guards the CI/CD files and the version bookkeeping that a release
# depends on.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
	WF="$REPO_DIR/.github/workflows"
}

# list_actions - the action of every `uses:` key. Anchored at the start of
# the line: "statuses: write" also contains the text "uses: write".
list_actions() {
	sed -nE 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+([^ ]+).*/\2/p' "$WF"/*.yml
}

@test "every workflow is valid YAML and sets explicit permissions" {
	for f in "$WF"/*.yml; do
		python3 -c "import sys, yaml; d = yaml.safe_load(open(sys.argv[1])); assert 'jobs' in d" "$f"
		grep -q '^permissions:' "$f"
	done
}

@test "no workflow uses pull_request_target or untrusted event text in run steps" {
	if grep -q 'pull_request_target' "$WF"/*.yml; then false; fi
	! grep -nE 'run:.*\$\{\{ *github\.(head_ref|event\.(issue|pull_request|comment))' "$WF"/*.yml
}

@test "every third-party action is pinned to a version, not a branch" {
	run list_actions
	[ "$status" -eq 0 ]
	while read -r action; do
		[[ "$action" == *@* ]]
		[[ "${action##*@}" != "main" && "${action##*@}" != "master" ]]
	done <<<"$output"
}

@test "the CI gate and the release gate run the same script" {
	grep -q 'bash scripts/gate.sh' "$WF/ci.yml"
	grep -q 'bash scripts/gate.sh' "$WF/release.yml"
}

@test "the release tag check compares with the version in lib/common.sh" {
	grep -q 'DPISTACK_VERSION' "$WF/release.yml"
	grep -qE '^DPISTACK_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$REPO_DIR/lib/common.sh"
}

@test "the program version in tech.md is the one in the code" {
	code="$(sed -n 's/^DPISTACK_VERSION="\(.*\)"$/\1/p' "$REPO_DIR/lib/common.sh")"
	doc="$(sed -n 's/.*Program version: v\([0-9.]*\)\*\*.*/\1/p' "$REPO_DIR/tech.md" | head -1)"
	[ -n "$code" ]
	[ "$code" = "$doc" ]
}

@test "every action is pinned to a full commit SHA, not a movable tag" {
	run list_actions
	[ "$status" -eq 0 ]
	while read -r action; do
		[[ "${action##*@}" =~ ^[0-9a-f]{40}$ ]] || {
			echo "not pinned by SHA: $action"
			return 1
		}
	done <<<"$output"
}

@test "no workflow pipes a download into a shell" {
	if grep -nE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' "$WF"/*.yml; then false; fi
	! grep -nE 'bash <\((curl|wget)' "$WF"/*.yml
}

@test "a release tag must be on main" {
	grep -q 'merge-base --is-ancestor' "$WF/release.yml"
}

@test "files the release archive copies exist" {
	for f in README.md LICENSE dpistack.conf.example install.sh lib templates bin tests/data; do
		[ -e "$REPO_DIR/$f" ]
	done
}

@test "the release publishes the single-file installer and the panel binaries with checksums" {
	grep -q 'cp dpistack-install.sh dist/' "$WF/release.yml"
	grep -q 'dist/dpistack-install.sh ' "$WF/release.yml"
	grep -q 'dpistack-install.sh.sha256' "$WF/release.yml"
	[ -f "$REPO_DIR/dpistack-install.sh" ]
}

@test "the gate runs the panel screen tests with node" {
	grep -q 'node --test' "$REPO_DIR/scripts/gate.sh"
	[ -f "$REPO_DIR/panel/web/test/mode.test.mjs" ]
}

@test "the gate runs as root in every workflow: the installer refuses to run otherwise" {
	run grep -n 'scripts/gate.sh' "$WF"/ci.yml "$WF"/release.yml
	[ "$status" -eq 0 ]
	while IFS= read -r line; do
		[[ "$line" == *"sudo -E env"* ]] || {
			echo "gate not run through sudo: $line"
			return 1
		}
	done <<<"$output"
}

@test "gitleaks runs as a binary pinned by SHA-256, not through gitleaks-action" {
	run grep -c 'gitleaks/gitleaks-action' "$WF/security.yml"
	[ "$output" = "0" ]
	grep -qE 'GITLEAKS_SHA256: [0-9a-f]{64}$' "$WF/security.yml"
	grep -q 'sha256sum -c' "$WF/security.yml"
}

@test "dpistack.conf.example matches the tech.md 4.3 key table and lib/schema.sh defaults" {
	run bash "$REPO_DIR/scripts/check-conf-example.sh"
	[ "$status" -eq 0 ]
}

@test "the conf example check catches a key missing from the example" {
	work="$(mktemp -d)"
	mkdir -p "$work/scripts" "$work/lib"
	cp "$REPO_DIR/scripts/check-conf-example.sh" "$work/scripts/"
	cp "$REPO_DIR/lib/schema.sh" "$work/lib/"
	cp "$REPO_DIR/tech.md" "$work/"
	grep -v '^EVE_KEEP=' "$REPO_DIR/dpistack.conf.example" >"$work/dpistack.conf.example"
	run bash "$work/scripts/check-conf-example.sh"
	rm -rf "$work"
	[ "$status" -eq 1 ]
	[[ "$output" == *"EVE_KEEP"* ]]
}

@test "the conf example check catches a default that differs from the schema" {
	work="$(mktemp -d)"
	mkdir -p "$work/scripts" "$work/lib"
	cp "$REPO_DIR/scripts/check-conf-example.sh" "$work/scripts/"
	cp "$REPO_DIR/lib/schema.sh" "$work/lib/"
	cp "$REPO_DIR/tech.md" "$work/"
	sed 's/^PANEL_PORT=.*/PANEL_PORT=9999/' "$REPO_DIR/dpistack.conf.example" >"$work/dpistack.conf.example"
	run bash "$work/scripts/check-conf-example.sh"
	rm -rf "$work"
	[ "$status" -eq 1 ]
	[[ "$output" == *"default differs for PANEL_PORT"* ]]
}

@test "README covers what slice 25 requires" {
	for needle in "Topology limit" "Threat model" "Quick install" "dpistack.conf" "reconfigure" "dpistack" "scrape_configs" "VictoriaMetrics" "vmagent" "Prometheus"; do
		grep -q "$needle" "$REPO_DIR/README.md" || {
			echo "README lacks: $needle"
			return 1
		}
	done
}

@test "every local link in README points to an existing file" {
	while IFS= read -r target; do
		[ -e "$REPO_DIR/$target" ] || {
			echo "broken link: $target"
			return 1
		}
	done < <(grep -oE '\]\([^)#:]+\)' "$REPO_DIR/README.md" | sed -E 's/^\]\((.*)\)$/\1/')
}

@test "no test has a bare '! command' before its last line: bats ignores it there (R138)" {
	local bad
	bad=$(awk '
		/^@test/ { intest = 1; pending = ""; next }
		intest && /^}/ { intest = 0; pending = ""; next }
		intest {
			if ($0 ~ /^[ \t]*(#|$)/) next
			if (pending != "") { print FILENAME ":" pend_line ": " pending; pending = "" }
			if ($0 ~ /^\t! /) { pending = $0; pend_line = FNR }
		}' "$REPO_DIR"/tests/*.bats)
	[ -z "$bad" ] || {
		echo "$bad" >&2
		false
	}
}
