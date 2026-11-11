package api

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// alertScript stands in for `alerts list|history|ack|...`: it logs its
// arguments and answers with a file, or refuses when REFUSE exists.
const alertScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
[ -f "$dir/REFUSE" ] && { echo "dpistack: alerts: no such alert" >&2; exit 5; }
case "$2" in
list) cat "$dir/alerts-list.json" ;;
history) cat "$dir/alerts-history.json" ;;
*) ;;
esac
`

var alertFiles = map[string]string{
	"alerts-list.json":    `{"ts":"2026-01-01T00:00:00Z","alerts":[{"key":"watch:disk.free","state":"new","severity":"crit"}],"counts":{"new":1,"acknowledged":0,"snoozed":0,"resolved":0,"new_crit":1}}`,
	"alerts-history.json": `{"history":[{"ts":"2026-01-01T00:00:00Z","kind":"action","key":"watch:disk.free","action":"ack","by":"admin"}]}`,
}

func alertEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		files := map[string]string{"ctl": alertScript}
		for k, v := range alertFiles {
			files[k] = v
		}
		for name, text := range files {
			mode := os.FileMode(0o644)
			if name == "ctl" {
				mode = 0o755
			}
			if err := os.WriteFile(filepath.Join(dir, name), []byte(text), mode); err != nil {
				t.Fatal(err)
			}
		}
		c.Ctl = &ctl.Runner{Path: filepath.Join(dir, "ctl")}
	})
}

func TestAlertCenterListPassesTheVerbJSONThrough(t *testing.T) {
	e := alertEnv(t)
	w := e.as("vi", "GET", "/api/alert-center", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != alertFiles["alerts-list.json"] {
		t.Fatalf("list: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "alerts list --json\n") {
		t.Errorf("the verb was called with: %q", e.calls())
	}
	if w := e.as("vi", "GET", "/api/alert-center?state=new&source=suricata&severity=warn", ""); w.Code != 200 {
		t.Fatalf("filters: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "alerts list --json --state new --source suricata --severity warn\n") {
		t.Errorf("filters reach the verb as arguments: %q", e.calls())
	}
}

func TestAlertCenterListRefusesBadFiltersBeforeCtl(t *testing.T) {
	e := alertEnv(t)
	for _, q := range []string{"state=x", "source=x", "severity=x", "state=new;rm", "state=NEW"} {
		if w := e.as("vi", "GET", "/api/alert-center?"+q, ""); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d", q, w.Code)
		}
	}
	if strings.Contains(e.calls(), "alerts list") {
		t.Errorf("a refused filter reached the verb: %q", e.calls())
	}
}

func TestAlertCenterHistory(t *testing.T) {
	e := alertEnv(t)
	w := e.as("vi", "GET", "/api/alert-center/history", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != alertFiles["alerts-history.json"] {
		t.Fatalf("history: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "alerts history --json\n") {
		t.Errorf("default call: %q", e.calls())
	}
	if w := e.as("vi", "GET", "/api/alert-center/history?limit=50", ""); w.Code != 200 {
		t.Fatalf("limit: %d", w.Code)
	}
	if !strings.Contains(e.calls(), "alerts history --json --limit 50\n") {
		t.Errorf("limit call: %q", e.calls())
	}
	for _, q := range []string{"limit=0", "limit=501", "limit=abc", "limit=-1"} {
		if w := e.as("vi", "GET", "/api/alert-center/history?"+q, ""); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d", q, w.Code)
		}
	}
}

func TestAlertCenterActRunsTheVerbAsThePanelUser(t *testing.T) {
	e := alertEnv(t)
	w := e.as("an", "POST", "/api/alert-center", `{"action":"snooze","key":"sid:2001219","for":"4h","note":"ticket 7"}`)
	if w.Code != 200 {
		t.Fatalf("snooze: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "alerts snooze sid:2001219 --for 4h --note ticket 7 --by ") {
		t.Errorf("arguments: %q", e.calls())
	}
	if w := e.as("an", "POST", "/api/alert-center", `{"action":"ack","key":"watch:disk.free"}`); w.Code != 200 {
		t.Fatalf("ack: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "alerts ack watch:disk.free --by ") || strings.Contains(e.calls(), "ack watch:disk.free --for") {
		t.Errorf("ack arguments: %q", e.calls())
	}
}

func TestAlertCenterActRefusesBadInputBeforeCtl(t *testing.T) {
	e := alertEnv(t)
	for name, body := range map[string]string{
		"no action":      `{"key":"sid:1"}`,
		"bad action":     `{"action":"delete","key":"sid:1"}`,
		"bad key":        `{"action":"ack","key":"../etc"}`,
		"key injection":  `{"action":"ack","key":"sid:1;rm"}`,
		"snooze no for":  `{"action":"snooze","key":"sid:1"}`,
		"snooze 5h":      `{"action":"snooze","key":"sid:1","for":"5h"}`,
		"ack with for":   `{"action":"ack","key":"sid:1","for":"1h"}`,
		"bad note":       `{"action":"ack","key":"sid:1","note":"a\"b"}`,
		"long note":      `{"action":"ack","key":"sid:1","note":"` + strings.Repeat("a", 81) + `"}`,
		"not json":       `{`,
		"wrong shape":    `{"action":1}`,
		"upper watch id": `{"action":"ack","key":"watch:Disk"}`,
	} {
		if w := e.as("an", "POST", "/api/alert-center", body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	if strings.Contains(e.calls(), "alerts ack") || strings.Contains(e.calls(), "alerts snooze") {
		t.Errorf("a refused request reached the verb: %q", e.calls())
	}
}

func TestAlertCenterActExitCodeFiveIsBadRequest(t *testing.T) {
	e := alertEnv(t)
	if err := os.WriteFile(filepath.Join(e.dir, "REFUSE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("an", "POST", "/api/alert-center", `{"action":"ack","key":"sid:9"}`); w.Code != http.StatusBadRequest {
		t.Errorf("code 5: %d %s", w.Code, w.Body)
	}
}

func TestAlertCenterPermissions(t *testing.T) {
	e := alertEnv(t)
	if w := e.as("vi", "GET", "/api/alert-center", ""); w.Code != 200 {
		t.Errorf("a viewer sees the alerts: %d", w.Code)
	}
	if w := e.as("vi", "POST", "/api/alert-center", `{"action":"ack","key":"sid:1"}`); w.Code != http.StatusForbidden {
		t.Errorf("a viewer may not acknowledge: %d", w.Code)
	}
	if w := e.as("an", "POST", "/api/alert-center", `{"action":"ack","key":"sid:1"}`); w.Code != 200 {
		t.Errorf("an analyst may: %d %s", w.Code, w.Body)
	}
}

func TestOldAlertsFeedIsUnchanged(t *testing.T) {
	e := alertEnv(t)
	w := e.as("vi", "GET", "/api/alerts", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"alerts"`) {
		t.Errorf("the status-change feed: %d %s", w.Code, w.Body)
	}
}
