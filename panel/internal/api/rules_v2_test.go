package api

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// rulesV2Script stands in for the verbs of Rules v2: it logs its arguments,
// keeps what it got on stdin, and answers with files, so a test decides what
// the verb "printed".
const rulesV2Script = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
case "$1" in
rules-stats) cat "$dir/stats.json" ;;
rules-history) cat "$dir/history.json" ;;
rules-describe) printf '{"rules":[],"asked":%s}\n' "$(($# - 1))" ;;
rules-local)
  cat > "$dir/stdin.txt"
  [ -f "$dir/REFUSE" ] && { echo "dpistack: rules-local check: the file is larger than 1048576 bytes" >&2; exit 5; }
  cat "$dir/local.json" ;;
config-history)
  if [ -n "$3" ]; then
    [ "$3" = 20990101T000000Z ] && { echo "dpistack: config-history: no such version: $3" >&2; exit 4; }
    printf 'content of %s\n' "$3"
  else
    cat "$dir/versions.json"
  fi ;;
esac
`

var rulesV2Files = map[string]string{
	"stats.json":    `{"ruleset":{"present":true,"updated":"2026-11-09T06:43:33Z","total":5,"enabled":3,"disabled":2},"local":{"total":2,"enabled":1,"disabled":1},"sources":[{"name":"test/one","cached":true,"total":3,"enabled":2,"disabled":1,"missing":0,"fetched":"2026-11-09T06:43:33Z"}]}`,
	"history.json":  `{"updates":[{"time":"2026-11-09T06:00:00Z","result":"ok","loaded":5,"total":5,"enabled":3,"added":4,"removed":1,"modified":2,"parsed":true}]}`,
	"local.json":    `{"ok":false,"rules":2,"problems":[{"line":1,"kind":"conflict","text":"sid 1000001 is already used by the rule set: ONE a"}],"warnings":[],"suricata":{"run":true,"ok":true,"output":""}}`,
	"versions.json": `{"name":"local.rules","versions":[{"id":"20261108T101010Z","time":"2026-11-08T10:10:10Z","size":120,"lines":2}]}`,
}

func rulesV2Env(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		files := map[string]string{"ctl": rulesV2Script}
		for k, v := range rulesV2Files {
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

func TestRulesStatsAndHistoryPassTheVerbJSONThrough(t *testing.T) {
	e := rulesV2Env(t)
	for path, want := range map[string]string{"/api/rules/stats": rulesV2Files["stats.json"], "/api/rules/history": rulesV2Files["history.json"]} {
		w := e.as("vi", "GET", path, "")
		if w.Code != 200 || strings.TrimSpace(w.Body.String()) != want {
			t.Errorf("%s: %d %s", path, w.Code, w.Body)
		}
		if ct := w.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("%s content type %q", path, ct)
		}
	}
	if !strings.Contains(e.calls(), "rules-stats --json\n") || !strings.Contains(e.calls(), "rules-history --json\n") {
		t.Errorf("the verbs were called with: %q", e.calls())
	}
}

func TestRulesAnswerThatIsNotJSONIsAServerError(t *testing.T) {
	e := rulesV2Env(t)
	if err := os.WriteFile(filepath.Join(e.dir, "stats.json"), []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("vi", "GET", "/api/rules/stats", ""); w.Code != http.StatusInternalServerError {
		t.Errorf("a verb that printed text: %d %s", w.Code, w.Body)
	}
}

func TestRulesDescribeChecksTheNumbersBeforeCtl(t *testing.T) {
	e := rulesV2Env(t)
	if w := e.as("vi", "GET", "/api/rules/describe?sids=2001219,2210044", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"asked":2`) {
		t.Fatalf("describe: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "rules-describe 2001219 2210044\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	var many []string
	for i := 1; i <= 21; i++ {
		many = append(many, "1")
	}
	before := e.calls()
	for name, q := range map[string]string{
		"none":     "",
		"empty":    "?sids=",
		"letters":  "?sids=abc",
		"shell":    "?sids=1;rm",
		"negative": "?sids=-5",
		"too long": "?sids=12345678901",
		"21 sids":  "?sids=" + strings.Join(many, ","),
		"gap":      "?sids=1,,2",
	} {
		w := e.as("vi", "GET", "/api/rules/describe"+q, "")
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s, want 400", name, w.Code, w.Body)
		}
	}
	if strings.Count(e.calls(), "rules-describe") != strings.Count(before, "rules-describe") {
		t.Errorf("a refused value reached ctl:\n%s", e.calls())
	}
}

func TestRulesLocalCheckSendsTheBodyAsIsAndNeedsRulesEdit(t *testing.T) {
	e := rulesV2Env(t)
	body := "alert tcp any any -> any 80 (msg:\"x\"; sid:9100001; rev:1;)\n# note\n"
	w := e.as("op", "POST", "/api/rules/local/check", body)
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != rulesV2Files["local.json"] {
		t.Fatalf("check: %d %s", w.Code, w.Body)
	}
	got, err := os.ReadFile(filepath.Join(e.dir, "stdin.txt"))
	if err != nil || string(got) != body {
		t.Errorf("stdin of the verb: %q, %v", got, err)
	}
	if !strings.Contains(e.calls(), "rules-local check\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	for _, user := range []string{"vi", "an"} {
		if w := e.as(user, "POST", "/api/rules/local/check", body); !isForbidden(w) {
			t.Errorf("%s: %d, want 403", user, w.Code)
		}
	}
	if w := e.do(req{method: "POST", path: "/api/rules/local/check"}); w.Code != http.StatusUnauthorized {
		t.Errorf("no session: %d", w.Code)
	}
}

func TestRulesLocalCheckLimitsAndRefusals(t *testing.T) {
	e := rulesV2Env(t)
	before := e.calls()
	big := strings.Repeat("a", maxConfigBody+1)
	if w := e.as("op", "POST", "/api/rules/local/check", big); w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("over 1 MiB: %d", w.Code)
	}
	if e.calls() != before {
		t.Errorf("an oversized body reached ctl")
	}
	if err := os.WriteFile(filepath.Join(e.dir, "REFUSE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("op", "POST", "/api/rules/local/check", "x"); w.Code < 400 || !strings.Contains(w.Body.String(), "larger than") {
		t.Errorf("a refusal of the verb: %d %s", w.Code, w.Body)
	}
}

func TestConfigHistoryAndVersion(t *testing.T) {
	e := rulesV2Env(t)
	w := e.as("admin", "GET", "/api/config/local.rules/history", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != rulesV2Files["versions.json"] {
		t.Fatalf("history: %d %s", w.Code, w.Body)
	}
	w = e.as("admin", "GET", "/api/config/local.rules/history/20261108T101010Z", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"content":"content of 20261108T101010Z\n"`) {
		t.Fatalf("version: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "config-history local.rules\n") || !strings.Contains(e.calls(), "config-history local.rules 20261108T101010Z\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	before := e.calls()
	for name, path := range map[string]string{
		"unknown file":   "/api/config/passwd/history",
		"traversal":      "/api/config/..%2F..%2Fetc%2Fpasswd/history",
		"bad id":         "/api/config/local.rules/history/not-an-id",
		"id traversal":   "/api/config/local.rules/history/..%2F..%2Fetc%2Fpasswd",
		"id with suffix": "/api/config/local.rules/history/20261108T101010Z;rm",
	} {
		if w := e.as("admin", "GET", path, ""); w.Code != http.StatusBadRequest && w.Code != http.StatusNotFound {
			t.Errorf("%s: %d, want 400 or 404", name, w.Code)
		}
	}
	if e.calls() != before {
		t.Errorf("a refused name or id reached ctl:\n%s", e.calls())
	}
	if w := e.as("admin", "GET", "/api/config/local.rules/history/20990101T000000Z", ""); w.Code != http.StatusConflict {
		t.Errorf("no such version: %d %s", w.Code, w.Body)
	}
}

func TestConfigHistoryNeedsConfigsEdit(t *testing.T) {
	e := rulesV2Env(t)
	for _, user := range []string{"vi", "an", "op"} {
		for _, path := range []string{"/api/config/local.rules/history", "/api/config/local.rules/history/20261108T101010Z"} {
			if w := e.as(user, "GET", path, ""); !isForbidden(w) {
				t.Errorf("%s %s: %d, want 403", user, path, w.Code)
			}
		}
	}
	if w := e.do(req{method: "GET", path: "/api/config/local.rules/history"}); w.Code != http.StatusUnauthorized {
		t.Errorf("no session: %d", w.Code)
	}
}
