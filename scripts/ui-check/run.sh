#!/usr/bin/env bash
# run.sh [output directory] - builds the panel, starts it with a stub of the
# dpistack command (canned answers) and runs check.mjs against it. Needs Go and
# Node; the browser comes from the npm package @sparticuz/chromium.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${1:-$here/shots}"
port="${UI_CHECK_PORT:-9800}"
work="$(mktemp -d)"
panel_pid=""
cleanup() {
	[[ -z "$panel_pid" ]] || kill "$panel_pid" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

# UI_CHECK_GOFLAGS: extra flags for go build (a sandbox without the module proxy)
# shellcheck disable=SC2086
(cd "$root/panel" && go build ${UI_CHECK_GOFLAGS:-} -o "$work/panel" ./cmd/panel)

# the password of the Go tests ("correct horse") and a stub of the command
# shellcheck disable=SC2016 # a hash, not an expansion
printf '%s\n' '$argon2id$v=19$m=16384,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$06P4n5MT+1p4xkEaN81bac/LFLj2y/TdZ8HFiBx7mOc' >"$work/panel.auth"
cat >"$work/ctl" <<'STUB'
#!/bin/sh
case "$*" in
*settings*list*) cat "$(dirname "$0")/settings.json" ;;
*status*) cat <<'JSON'
{"components":[
{"id":"suricata","runtime":"native","state":"active","enabled":true,"version":"8.0.8"},
{"id":"evebox","runtime":"native","state":"active","enabled":true,"version":"1:0.31.0"},
{"id":"ntopng","runtime":"native","state":"active","enabled":true,"version":"7.0.261106-29868"},
{"id":"redis","runtime":"native","state":"active","enabled":true,"version":"5:8.0.2"},
{"id":"panel","runtime":"native","state":"active","enabled":true,"version":""},
{"id":"watch","runtime":"native","state":"inactive","enabled":true,"version":""},
{"id":"rules","runtime":"native","state":"failed","enabled":true,"version":""}],"ndpi_plugin":"loaded"}
JSON
	;;
*) echo '{}' ;;
esac
STUB
cp "$here/settings.json" "$work/settings.json"
cp "$here/eve.sample.json" "$work/eve.json"
chmod +x "$work/ctl"

"$work/panel" -addr "127.0.0.1:$port" -auth-file "$work/panel.auth" -users-file "$work/none.json" \
	-audit-file "" -eve-file "$work/eve.json" -health-file "$work/health.json" -ctl "$work/ctl" -sudo=false \
	-version 0.0.0 -update-url off >"$work/panel.log" 2>&1 &
panel_pid=$!
sleep 2

(cd "$here" && npm ci --silent --no-audit --no-fund)
(cd "$here" && node check.mjs "http://127.0.0.1:$port/" "$out")
