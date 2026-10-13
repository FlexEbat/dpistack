#!/usr/bin/env bash
# Resource budget of the panel (tech.md 9): static files at most 150 KB
# before compression, the binary at most 15 MB, resident memory of an idle
# panel at most 25 MB. Builds the panel, so it needs Go.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

MAX_STATIC_KB=150
MAX_BINARY_MB=15
MAX_RSS_MB=25

work=$(mktemp -d)
pid=""
# shellcheck disable=SC2317 # runs from the EXIT trap
cleanup() {
	if [[ -n "$pid" ]]; then
		kill "$pid" 2>/dev/null || true
	fi
	rm -rf "$work"
}
trap cleanup EXIT

fail=0
check() {
	# check <label> <value> <limit> <unit>
	if (($2 > $3)); then
		echo "FAIL: panel budget: $1 is $2 $4, the limit is $3 $4"
		fail=1
	else
		echo "panel budget: $1 $2 $4 (limit $3 $4)"
	fi
}

static_bytes=$(find panel/web -type f ! -name '*.go' -print0 | xargs -0 cat | wc -c)
check "static files" $(((static_bytes + 1023) / 1024)) "$MAX_STATIC_KB" KB

(cd panel && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$work/panel" ./cmd/panel)
binary_bytes=$(stat -c %s "$work/panel")
check "binary" $(((binary_bytes + 1048575) / 1048576)) "$MAX_BINARY_MB" MB

# An idle panel: started, asked once for the login page, then left alone.
port=$((20000 + RANDOM % 20000))
printf '#!/bin/sh\necho "{\\"components\\":[],\\"ndpi_plugin\\":\\"absent\\"}"\n' >"$work/ctl"
chmod 0755 "$work/ctl"
"$work/panel" -addr "127.0.0.1:$port" -auth-file "$work/panel.auth" \
	-health-file "$work/health.json" -ctl "$work/ctl" -sudo=false >"$work/log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
	grep -q listening "$work/log" 2>/dev/null && break
	sleep 0.1
done
if ! grep -q listening "$work/log"; then
	echo "FAIL: panel budget: the panel did not start"
	cat "$work/log"
	exit 1
fi
curl -fsS -o /dev/null "http://127.0.0.1:$port/"
sleep 3
rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")
check "idle resident memory" $(((rss_kb + 1023) / 1024)) "$MAX_RSS_MB" MB

exit "$fail"
