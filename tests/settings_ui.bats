#!/usr/bin/env bats
# The settings screen shows every key of the schema with a hint, and the page
# loads its module.

setup() {
	REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "every schema key has a hint on the settings screen" {
	schema_keys=$(bash -c 'source "'"$REPO_DIR"'/lib/schema.sh"; printf "%s\n" "${SCHEMA_KEYS[@]}"' | sort)
	hint_keys=$(sed -n 's/^  \([A-Z][A-Z0-9_]*\): ".*/\1/p' "$REPO_DIR/panel/web/modules/settings-model.js" | sort)
	[ "$schema_keys" = "$hint_keys" ]
}

@test "the page has the settings view and the navigation entry, and app.js starts the module" {
	grep -q 'id="view-settings"' "$REPO_DIR/panel/web/index.html"
	grep -q 'data-view="settings"' "$REPO_DIR/panel/web/index.html"
	grep -q 'startSettings' "$REPO_DIR/panel/web/app.js"
}

@test "the page uses no inline script or style, no external resource" {
	! grep -qE '<script[^>]*>[^<]+|style=|https?://' "$REPO_DIR/panel/web/index.html"
	! grep -qE 'https?://' "$REPO_DIR/panel/web/app.css"
}
