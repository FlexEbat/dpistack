package api

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// profileScript stands in for `settings profile ...`: it logs its arguments,
// keeps what `save` read on stdin, and refuses with REFUSE_RC when that file
// exists.
const profileScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
[ -f "$dir/REFUSE_RC" ] && { echo "dpistack: refused" >&2; exit $(cat "$dir/REFUSE_RC"); }
[ "$1 $2" = "settings profile" ] || exit 0
case "$3" in
list) cat "$dir/profiles-list.json" ;;
show) cat "$dir/profiles-show.json" ;;
save) cat > "$dir/stdin.save" ;;
esac
`

var profileFiles = map[string]string{
	"profiles-list.json": `{"profiles":[{"name":"lan-watch","created":"2026-01-01T00:00:00Z","by":"admin","count":2}]}`,
	"profiles-show.json": `{"name":"lan-watch","created":"2026-01-01T00:00:00Z","by":"admin","keys":{"ACCESS_MODE":"lan","WATCH_INTERVAL_SEC":"30"}}`,
}

func profileEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		files := map[string]string{"ctl": profileScript}
		for k, v := range profileFiles {
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

func TestProfilesListAndShowPassTheVerbJSONThrough(t *testing.T) {
	e := profileEnv(t)
	w := e.as("vi", "GET", "/api/settings/profiles", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != profileFiles["profiles-list.json"] {
		t.Fatalf("list: %d %s", w.Code, w.Body)
	}
	w = e.as("vi", "GET", "/api/settings/profiles/lan-watch", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != profileFiles["profiles-show.json"] {
		t.Fatalf("show: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "settings profile list --json\n") || !strings.Contains(e.calls(), "settings profile show lan-watch --json\n") {
		t.Errorf("calls: %q", e.calls())
	}
}

func TestProfileSaveSendsThePairsOnStdinAndTheUserOnTheCommandLine(t *testing.T) {
	e := profileEnv(t)
	w := e.as("admin", "PUT", "/api/settings/profiles/lan-watch", `{"values":{"WATCH_INTERVAL_SEC":"30","BPF_FILTER":"not (host 10.0.0.1)"}}`)
	if w.Code != 200 {
		t.Fatalf("save: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "settings profile save lan-watch --by admin\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	got, err := os.ReadFile(filepath.Join(e.dir, "stdin.save"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "BPF_FILTER=not (host 10.0.0.1)\nWATCH_INTERVAL_SEC=30\n" {
		t.Errorf("stdin, sorted by key: %q", got)
	}
}

func TestProfileSaveRefusesBadInputBeforeCtl(t *testing.T) {
	e := profileEnv(t)
	long := strings.Repeat("a", 33)
	for name, c := range map[string]struct{ path, body string }{
		"upper name":  {"/api/settings/profiles/Lan", `{"values":{"A_B":"1"}}`},
		"long name":   {"/api/settings/profiles/" + long, `{"values":{"A_B":"1"}}`},
		"dash first":  {"/api/settings/profiles/-x", `{"values":{"A_B":"1"}}`},
		"no values":   {"/api/settings/profiles/ok", `{"values":{}}`},
		"bad key":     {"/api/settings/profiles/ok", `{"values":{"a b":"1"}}`},
		"line break":  {"/api/settings/profiles/ok", `{"values":{"A_B":"1\nC=2"}}`},
		"not json":    {"/api/settings/profiles/ok", `{`},
		"wrong shape": {"/api/settings/profiles/ok", `{"values":"x"}`},
	} {
		if w := e.as("admin", "PUT", c.path, c.body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	if w := e.as("admin", "GET", "/api/settings/profiles/Lan", ""); w.Code != http.StatusBadRequest {
		t.Errorf("show with a bad name: %d", w.Code)
	}
	if w := e.as("admin", "DELETE", "/api/settings/profiles/Lan", ""); w.Code != http.StatusBadRequest {
		t.Errorf("delete with a bad name: %d", w.Code)
	}
	if strings.Contains(e.calls(), "profile save") || strings.Contains(e.calls(), "profile delete") || strings.Contains(e.calls(), "profile show") {
		t.Errorf("a refused request reached the verb: %q", e.calls())
	}
}

func TestProfileDeleteRunsTheVerbAsThePanelUser(t *testing.T) {
	e := profileEnv(t)
	if w := e.as("admin", "DELETE", "/api/settings/profiles/lan-watch", ""); w.Code != 200 {
		t.Fatalf("delete: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "settings profile delete lan-watch --by admin\n") {
		t.Errorf("arguments: %q", e.calls())
	}
}

func TestProfileVerbRefusalsBecomeStatusCodes(t *testing.T) {
	e := profileEnv(t)
	if err := os.WriteFile(filepath.Join(e.dir, "REFUSE_RC"), []byte("5"), 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("admin", "PUT", "/api/settings/profiles/x", `{"values":{"WATCH_INTERVAL_SEC":"30"}}`); w.Code != http.StatusBadRequest {
		t.Errorf("exit 5: %d %s", w.Code, w.Body)
	}
	if w := e.as("admin", "DELETE", "/api/settings/profiles/x", ""); w.Code != http.StatusBadRequest {
		t.Errorf("delete exit 5: %d %s", w.Code, w.Body)
	}
	if err := os.WriteFile(filepath.Join(e.dir, "REFUSE_RC"), []byte("3"), 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("admin", "PUT", "/api/settings/profiles/x", `{"values":{"WATCH_INTERVAL_SEC":"30"}}`); w.Code == 200 {
		t.Errorf("values the verb refused must not answer 200: %d", w.Code)
	}
}

func TestProfilePermissions(t *testing.T) {
	e := profileEnv(t)
	if w := e.as("vi", "GET", "/api/settings/profiles", ""); w.Code != 200 {
		t.Errorf("a viewer sees the profiles: %d", w.Code)
	}
	for _, who := range []string{"vi", "an", "cu"} {
		if w := e.as(who, "PUT", "/api/settings/profiles/x", `{"values":{"WATCH_INTERVAL_SEC":"30"}}`); w.Code != http.StatusForbidden {
			t.Errorf("%s may not save: %d", who, w.Code)
		}
		if w := e.as(who, "DELETE", "/api/settings/profiles/x", ""); w.Code != http.StatusForbidden {
			t.Errorf("%s may not delete: %d", who, w.Code)
		}
	}
	if w := e.as("admin", "PUT", "/api/settings/profiles/x", `{"values":{"WATCH_INTERVAL_SEC":"30"}}`); w.Code != 200 {
		t.Errorf("an admin may save: %d %s", w.Code, w.Body)
	}
}
