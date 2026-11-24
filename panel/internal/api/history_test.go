package api

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

const historyScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
case "$1" in
report) echo '{"label":"'"$2"'","flows":3,"days":["2026-11-20"],"apps":[],"devices":[],"alerts":[],"new_devices":[]}' ;;
devices) echo '[{"ip":"10.0.0.5","first":"2026-11-01","last":"2026-11-20"}]' ;;
*) exit 2 ;;
esac
`

func historyEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		if err := os.WriteFile(filepath.Join(dir, "ctl"), []byte(historyScript), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: filepath.Join(dir, "ctl")}
	})
}

func TestHistoryReportRunsTheVerb(t *testing.T) {
	e := historyEnv(t)
	w := e.as("vi", "GET", "/api/history/report?kind=weekly&date=2026-11-20", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"label":"weekly"`) {
		t.Fatalf("a viewer reads a report: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "report weekly --date 2026-11-20 --json\n") {
		t.Errorf("the verb got: %q", e.calls())
	}
	// kind defaults to daily and date to the verb's own today
	w = e.as("vi", "GET", "/api/history/report", "")
	if w.Code != 200 || !strings.Contains(e.calls(), "report daily --json\n") {
		t.Errorf("defaults: %d %q", w.Code, e.calls())
	}
}

func TestHistoryReportRefusesBadInput(t *testing.T) {
	e := historyEnv(t)
	for _, q := range []string{"?kind=monthly", "?date=yesterday", "?date=2026-11-20;rm", "?kind=daily&date=20261120"} {
		before := e.calls()
		if w := e.as("vi", "GET", "/api/history/report"+q, ""); w.Code != 400 {
			t.Errorf("%s: %d", q, w.Code)
		}
		if e.calls() != before {
			t.Errorf("%s reached the verb", q)
		}
	}
}

func TestHistoryDevices(t *testing.T) {
	e := historyEnv(t)
	w := e.as("vi", "GET", "/api/history/devices", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"ip":"10.0.0.5"`) {
		t.Fatalf("devices: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "devices --json\n") {
		t.Errorf("the verb got: %q", e.calls())
	}
}
