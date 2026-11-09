package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// exceptionsScript stands in for `dpistack exceptions`: it logs its
// arguments, answers list with a file, and fails the way the real verb does
// (2 and 5 a refused value, 3 a file that does not pass suricata -T, 4 an
// entry that is not there, 1 an entry that already exists).
const exceptionsScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
[ "$1" = exceptions ] || exit 2
case "$2" in
list) cat "$dir/list.json" ;;
add)
  [ -f "$dir/CHECK_FAIL" ] && { echo "ERROR: invalid threshold line"; echo "dpistack: exceptions: threshold.config does not pass suricata -T, file unchanged" >&2; exit 3; }
  [ -f "$dir/EXISTS" ] && { echo "dpistack: exceptions add: already exists; remove it first" >&2; exit 1; }
  case "$*" in *"--track src"*) ;; *"suppress"*"--ip"*) echo "dpistack: exceptions add suppress: --ip needs --track src|dst" >&2; exit 2 ;; esac
  echo "warning: nothing" >&2
  echo "$3:$4:src:10.0.0.5" ;;
remove)
  [ "$3" = "suppress:1:src:10.9.9.9" ] && { echo "dpistack: exceptions remove: no such entry: $3" >&2; exit 4; }
  echo "removed $3" ;;
esac
`

const exceptionsList = `{"default_days":30,"today":"2026-11-08","entries":[` +
	`{"id":"suppress:2001219:src:10.0.0.5","kind":"suppress","sid":2001219,"track":"src","ip":"10.0.0.5","count":0,"seconds":0,"added":"2026-11-01","expires":"2026-12-01","days_left":23,"expired":false,"by":"admin","note":"printer scans"},` +
	`{"id":"suppress:2210044:any:any","kind":"suppress","sid":2210044,"track":"any","ip":"any","count":0,"seconds":0,"added":"2026-11-02","expires":"never","days_left":null,"expired":false,"by":"admin","note":""}]}`

func exceptionsEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		for name, text := range map[string]string{"ctl": exceptionsScript, "list.json": exceptionsList} {
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

type exceptionsAnswer struct {
	DefaultDays int `json:"default_days"`
	Entries     []struct {
		ID       string `json:"id"`
		DaysLeft *int   `json:"days_left"`
		Expires  string `json:"expires"`
	} `json:"entries"`
}

func TestExceptionsList(t *testing.T) {
	e := exceptionsEnv(t)
	w := e.as("vi", "GET", "/api/exceptions", "")
	if w.Code != 200 {
		t.Fatalf("a viewer reads the list: %d %s", w.Code, w.Body)
	}
	var a exceptionsAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &a); err != nil {
		t.Fatal(err)
	}
	if a.DefaultDays != 30 || len(a.Entries) != 2 {
		t.Fatalf("answer: %+v", a)
	}
	if a.Entries[0].DaysLeft == nil || *a.Entries[0].DaysLeft != 23 {
		t.Errorf("days left of the first entry: %v", a.Entries[0].DaysLeft)
	}
	if a.Entries[1].DaysLeft != nil || a.Entries[1].Expires != "never" {
		t.Errorf("an entry that never expires has no days left: %+v", a.Entries[1])
	}
	if !strings.Contains(e.calls(), "exceptions list --json") {
		t.Errorf("the list comes from the verb: %q", e.calls())
	}
}

// The dashboard sends exactly the options the CLI takes, the user comes from
// the session and not from the body, and "never" and a bare SID go through.
func TestExceptionsAddRunsTheVerb(t *testing.T) {
	e := exceptionsEnv(t)
	for _, c := range []struct{ name, body, want string }{
		{"suppress for one address", `{"kind":"suppress","sid":2001219,"track":"src","ip":"10.0.0.5","days":10,"note":"printer scans","by":"mallory"}`,
			"exceptions add suppress 2001219 --track src --ip 10.0.0.5 --days 10 --note printer scans --by op"},
		{"a bare sid that never expires", `{"kind":"suppress","sid":2210044,"never":true}`, "exceptions add suppress 2210044 --by op --never"},
		{"a limit", `{"kind":"limit","sid":2210044,"track":"dst","count":5,"seconds":60,"never":true}`,
			"exceptions add limit 2210044 --track dst --count 5 --seconds 60 --by op --never"},
	} {
		w := e.as("op", "POST", "/api/exceptions", c.body)
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"ok":true`) {
			t.Fatalf("%s: %d %s", c.name, w.Code, w.Body)
		}
		if !strings.Contains(e.calls(), c.want+"\n") {
			t.Errorf("%s: the verb got\n%s\nwant a line %q", c.name, e.calls(), c.want)
		}
	}
}

// A value ctl would refuse is not sent; the user gets a sentence.
func TestExceptionsValuesAreCheckedBeforeCtl(t *testing.T) {
	e := exceptionsEnv(t)
	for name, body := range map[string]string{
		"unknown kind":    `{"kind":"pass","sid":1}`,
		"no sid":          `{"kind":"suppress"}`,
		"negative sid":    `{"kind":"suppress","sid":-4}`,
		"bad track":       `{"kind":"suppress","sid":1,"track":"up","ip":"10.0.0.1"}`,
		"shell in the ip": `{"kind":"suppress","sid":1,"track":"src","ip":"10.0.0.1;rm"}`,
		"shell in note":   `{"kind":"suppress","sid":1,"note":"a;b"}`,
		"days and never":  `{"kind":"suppress","sid":1,"days":3,"never":true}`,
		"negative days":   `{"kind":"suppress","sid":1,"days":-1}`,
		"not json":        `nope`,
	} {
		w := e.as("op", "POST", "/api/exceptions", body)
		if w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s, want 400", name, w.Code, w.Body)
		}
	}
	if strings.Contains(e.calls(), "exceptions add") {
		t.Errorf("a refused value reached ctl:\n%s", e.calls())
	}
	w := e.as("op", "POST", "/api/exceptions/remove", `{"id":"suppress:1:src:10.0.0.1;rm"}`)
	if w.Code != http.StatusBadRequest || strings.Contains(e.calls(), "exceptions remove") {
		t.Errorf("a bad id: %d, calls %q", w.Code, e.calls())
	}
}

// What the verb refuses comes back as a status the screen can explain.
func TestExceptionsVerbRefusalsAreMapped(t *testing.T) {
	e := exceptionsEnv(t)
	// Exit 2: a combination the verb refuses (an address with no side).
	if w := e.as("op", "POST", "/api/exceptions", `{"kind":"suppress","sid":1,"ip":"10.0.0.1"}`); w.Code != 400 || !strings.Contains(w.Body.String(), "--ip needs --track") {
		t.Errorf("exit 2: %d %s", w.Code, w.Body)
	}
	// Exit 1: it exists already.
	touch(t, e, "EXISTS")
	if w := e.as("op", "POST", "/api/exceptions", `{"kind":"suppress","sid":1,"track":"src","ip":"10.0.0.5"}`); w.Code != 500 || !strings.Contains(w.Body.String(), "already exists") {
		t.Errorf("exit 1: %d %s", w.Code, w.Body)
	}
	os.Remove(filepath.Join(e.dir, "EXISTS"))
	// Exit 3: the file does not pass suricata -T, and the output comes along.
	touch(t, e, "CHECK_FAIL")
	w := e.as("op", "POST", "/api/exceptions", `{"kind":"suppress","sid":1,"track":"src","ip":"10.0.0.5"}`)
	if w.Code != http.StatusUnprocessableEntity || !strings.Contains(w.Body.String(), "invalid threshold line") || !strings.Contains(w.Body.String(), "nothing was changed") {
		t.Errorf("exit 3: %d %s", w.Code, w.Body)
	}
	os.Remove(filepath.Join(e.dir, "CHECK_FAIL"))
	// Exit 4 on remove: no such entry.
	if w := e.as("op", "POST", "/api/exceptions/remove", `{"id":"suppress:1:src:10.9.9.9"}`); w.Code != http.StatusConflict {
		t.Errorf("exit 4: %d %s", w.Code, w.Body)
	}
	if w := e.as("op", "POST", "/api/exceptions/remove", `{"id":"suppress:2001219:src:10.0.0.5"}`); w.Code != 200 || !strings.Contains(e.calls(), "exceptions remove suppress:2001219:src:10.0.0.5\n") {
		t.Errorf("remove: %d %s calls %q", w.Code, w.Body, e.calls())
	}
}

func touch(t *testing.T, e *env, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(e.dir, name), nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

// Reading needs the view permission, changing needs rules.edit, and every
// route needs a session.
func TestExceptionsPermissions(t *testing.T) {
	e := exceptionsEnv(t)
	for _, r := range []struct{ method, path string }{
		{"GET", "/api/exceptions"}, {"POST", "/api/exceptions"}, {"POST", "/api/exceptions/remove"},
	} {
		if w := e.do(req{method: r.method, path: r.path}); w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s without a session: %d, want 401", r.method, r.path, w.Code)
		}
	}
	for _, user := range []string{"vi", "an"} {
		if w := e.as(user, "POST", "/api/exceptions", `{"kind":"suppress","sid":1}`); !isForbidden(w) {
			t.Errorf("%s adds an exception: %d, want 403", user, w.Code)
		}
		if w := e.as(user, "POST", "/api/exceptions/remove", `{"id":"suppress:1:any:any"}`); !isForbidden(w) {
			t.Errorf("%s removes an exception: %d, want 403", user, w.Code)
		}
	}
	for _, user := range []string{"op", "cu", "admin"} {
		if w := e.as(user, "POST", "/api/exceptions", `{"kind":"suppress","sid":1,"never":true}`); w.Code != 200 {
			t.Errorf("%s adds an exception: %d %s, want 200", user, w.Code, w.Body)
		}
	}
	if strings.Contains(e.calls(), "--by vi") || strings.Contains(e.calls(), "--by an") {
		t.Errorf("a refused user reached ctl:\n%s", e.calls())
	}
}
