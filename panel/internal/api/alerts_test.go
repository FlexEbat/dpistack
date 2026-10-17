package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withEventsFile(path string) option {
	return func(cfg *Config, _ string) { cfg.EventsFile = path }
}

func alertLine(n int, check, from, to string) string {
	return fmt.Sprintf(`{"ts":"2026-10-15T10:%02d:00Z","check":%q,"from":%q,"to":%q,"detail":"detail %d"}`+"\n", n%60, check, from, to, n)
}

type alertsAnswer struct {
	Alerts []struct {
		TS, Check, From, To, Detail string
	}
	Checks      []string
	FilePresent bool `json:"file_present"`
	Error       string
}

func getAlerts(t *testing.T, e *env, query string) (int, alertsAnswer) {
	t.Helper()
	cookies, _ := e.login()
	w := e.do(req{method: "GET", path: "/api/alerts" + query, cookies: cookies})
	var a alertsAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &a); err != nil {
		t.Fatalf("not JSON: %q", w.Body)
	}
	return w.Code, a
}

func writeEvents(t *testing.T, text string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "events.jsonl")
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// Criterion 3: the lines of events.jsonl, newest first, filtered by check.
func TestAlertsNewestFirstWithACheckFilter(t *testing.T) {
	text := alertLine(1, "disk.free", "ok", "warn") +
		alertLine(2, "suricata.drop_rate", "ok", "warn") +
		alertLine(3, "disk.free", "warn", "crit") +
		alertLine(4, "rules.age", "ok", "warn") +
		alertLine(5, "disk.free", "crit", "ok")
	e := setup(t, withEventsFile(writeEvents(t, text)))

	code, a := getAlerts(t, e, "")
	if code != 200 || !a.FilePresent || len(a.Alerts) != 5 {
		t.Fatalf("all: %d %+v", code, a)
	}
	if a.Alerts[0].Detail != "detail 5" || a.Alerts[4].Detail != "detail 1" {
		t.Errorf("newest first expected: %v ... %v", a.Alerts[0].Detail, a.Alerts[4].Detail)
	}
	if a.Alerts[0].Check != "disk.free" || a.Alerts[0].From != "crit" || a.Alerts[0].To != "ok" || a.Alerts[0].TS == "" {
		t.Errorf("fields: %+v", a.Alerts[0])
	}
	if strings.Join(a.Checks, ",") != "disk.free,rules.age,suricata.drop_rate" {
		t.Errorf("checks for the filter menu: %v", a.Checks)
	}

	_, a = getAlerts(t, e, "?check=disk.free")
	if len(a.Alerts) != 3 || a.Alerts[0].Detail != "detail 5" || a.Alerts[2].Detail != "detail 1" {
		t.Errorf("filter: %+v", a.Alerts)
	}
	if len(a.Checks) != 3 {
		t.Errorf("the menu must keep every check while a filter is on: %v", a.Checks)
	}
	if _, a = getAlerts(t, e, "?check=suricata.drop_rate&limit=1"); len(a.Alerts) != 1 || a.Alerts[0].Detail != "detail 2" {
		t.Errorf("one drop_rate event: %+v", a.Alerts)
	}
	if _, a = getAlerts(t, e, "?check=ntopng.process"); a.Alerts == nil || len(a.Alerts) != 0 {
		t.Errorf("no events for a check must be an empty list: %+v", a.Alerts)
	}
	if _, a = getAlerts(t, e, "?limit=2"); len(a.Alerts) != 2 || a.Alerts[0].Detail != "detail 5" || a.Alerts[1].Detail != "detail 4" {
		t.Errorf("limit: %+v", a.Alerts)
	}

	for _, bad := range []string{"?limit=0", "?limit=501", "?limit=-1", "?limit=x", "?check=Disk", "?check=a%20b", "?check=" + strings.Repeat("a", 65)} {
		if code, _ := getAlerts(t, e, bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad, code)
		}
	}
	if code, a := getAlerts(t, e, "?limit=500"); code != 200 || len(a.Alerts) != 5 {
		t.Errorf("limit=500: %d %d", code, len(a.Alerts))
	}
}

func TestAlertsDefaultLimitIs100(t *testing.T) {
	var text string
	for i := 0; i < 130; i++ {
		text += alertLine(i, "disk.free", "ok", "warn")
	}
	e := setup(t, withEventsFile(writeEvents(t, text)))
	if _, a := getAlerts(t, e, ""); len(a.Alerts) != 100 || a.Alerts[0].Detail != "detail 129" {
		t.Errorf("default limit gave %d events, newest %q", len(a.Alerts), a.Alerts[0].Detail)
	}
}

func TestAlertsSkipBrokenLinesAndTolerateNoFile(t *testing.T) {
	text := alertLine(1, "disk.free", "ok", "warn") +
		"not json\n" + `{"ts":"x"}` + "\n\n" + `{"ts":"2026","check":"a","from":` + "\n" +
		alertLine(2, "rules.age", "ok", "warn")
	e := setup(t, withEventsFile(writeEvents(t, text)))
	if code, a := getAlerts(t, e, ""); code != 200 || len(a.Alerts) != 2 || a.Alerts[0].Check != "rules.age" {
		t.Errorf("broken lines: %d %+v", code, a.Alerts)
	}

	for name, opt := range map[string]option{
		"missing": withEventsFile(filepath.Join(t.TempDir(), "none.jsonl")),
		"unset":   withEventsFile(""),
	} {
		code, a := getAlerts(t, setup(t, opt), "")
		if code != 200 || a.FilePresent || a.Alerts == nil || len(a.Alerts) != 0 {
			t.Errorf("%s file: %d %+v", name, code, a)
		}
	}
}

// The file only grows, so only its tail is read; a line cut by that is
// dropped, and what is read is still newest first.
func TestAlertsReadOnlyTheTailOfABigFile(t *testing.T) {
	pad := strings.Repeat("x", 800)
	var b strings.Builder
	n := 0
	for b.Len() < 3*alertsTail {
		n++
		fmt.Fprintf(&b, `{"ts":"2026-10-15T10:00:00Z","check":"disk.free","from":"ok","to":"warn","detail":"%d %s"}`+"\n", n, pad)
	}
	path := writeEvents(t, b.String())
	e := setup(t, withEventsFile(path))

	code, a := getAlerts(t, e, "?limit=500")
	if code != 200 || len(a.Alerts) != 500 {
		t.Fatalf("%d, %d events", code, len(a.Alerts))
	}
	if !strings.HasPrefix(a.Alerts[0].Detail, fmt.Sprintf("%d ", n)) {
		t.Errorf("the newest event is not first: %.20s", a.Alerts[0].Detail)
	}
	for _, x := range a.Alerts {
		if !strings.HasSuffix(x.Detail, pad) {
			t.Fatal("a line cut by the tail got through")
		}
	}
}
