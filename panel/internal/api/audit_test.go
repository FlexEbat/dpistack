package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/audit"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

func auditEnv(t *testing.T) *env {
	return setup(t, func(c *Config, dir string) {
		path := filepath.Join(dir, "users.json")
		if err := os.WriteFile(path, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = path
		script := filepath.Join(dir, "ctl")
		if err := os.WriteFile(script, []byte(recorder), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: script}
		c.Audit = &audit.Log{Path: filepath.Join(dir, "audit.jsonl")}
	})
}

func (e *env) auditLines() []audit.Entry {
	e.t.Helper()
	list, err := (&audit.Log{Path: filepath.Join(e.dir, "audit.jsonl")}).Read(audit.Filter{Limit: audit.MaxRead})
	if err != nil {
		e.t.Fatal(err)
	}
	return list
}

func (e *env) auditRaw() string {
	b, _ := os.ReadFile(filepath.Join(e.dir, "audit.jsonl"))
	return string(b)
}

func find(list []audit.Entry, action string) *audit.Entry {
	for i := range list {
		if strings.Contains(list[i].Action, action) {
			return &list[i]
		}
	}
	return nil
}

func TestFailedAndGoodLoginsAreBothLoggedWithTheNameAndNoPassword(t *testing.T) {
	e := auditEnv(t)
	e.do(req{method: "POST", path: "/api/login", body: `{"username":"anna","password":"Sup3r-Secret-Guess"}`, remote: "192.168.1.30:1"})
	e.loginAs("vi")
	list := e.auditLines()
	bad := find(list, "login")
	if bad == nil {
		t.Fatalf("no login line: %v", list)
	}
	var seenBad, seenGood bool
	for _, l := range list {
		if l.User == "anna" && l.Result == audit.ResultDenied && l.IP == "192.168.1.30" {
			seenBad = true
		}
		if l.User == "vi" && l.Result == audit.ResultOK {
			seenGood = true
		}
	}
	if !seenBad || !seenGood {
		t.Errorf("bad=%v good=%v lines=%v", seenBad, seenGood, list)
	}
	if strings.Contains(e.auditRaw(), "Sup3r-Secret-Guess") || strings.Contains(e.auditRaw(), "correct horse") {
		t.Error("a password is in the audit log")
	}
}

func TestAMutatingCallIsLoggedWithItsUserAndAGetIsNot(t *testing.T) {
	e := auditEnv(t)
	e.as("admin", "GET", "/api/me", "")
	before := len(e.auditLines())
	w := e.as("admin", "POST", "/api/users", `{"name":"newbie","role":"viewer","password":"s3cret-pass-word"}`)
	if w.Code != http.StatusCreated {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	list := e.auditLines()
	l := find(list, "POST /api/users")
	if l == nil || l.User != "admin" || l.Result != audit.ResultOK || !strings.Contains(l.Detail, "user=newbie role=viewer") {
		t.Fatalf("line: %+v", l)
	}
	// as() signs in first, so the new lines are that login and the POST; the
	// GET of /api/me earlier added nothing.
	if len(list)-before != 2 {
		t.Errorf("%d new lines, want 2 (login and POST)", len(list)-before)
	}
	for _, x := range list {
		if strings.HasPrefix(x.Action, "GET") {
			t.Errorf("a GET was logged: %+v", x)
		}
	}
	if strings.Contains(e.auditRaw(), "s3cret-pass-word") {
		t.Error("the password of the new user is in the audit log")
	}
}

func TestADeniedCallIsLoggedAsDenied(t *testing.T) {
	e := auditEnv(t)
	e.as("vi", "POST", "/api/users", `{"name":"x","role":"viewer","password":"long enough pw"}`)
	l := find(e.auditLines(), "POST /api/users")
	if l == nil || l.User != "vi" || l.Result != audit.ResultDenied {
		t.Fatalf("line: %+v", l)
	}
}

func TestAnUnsignedCallIsLoggedWithADash(t *testing.T) {
	e := auditEnv(t)
	e.do(req{method: "POST", path: "/api/users", body: `{}`})
	l := find(e.auditLines(), "POST /api/users")
	if l == nil || l.User != "-" || l.Result != audit.ResultDenied {
		t.Fatalf("line: %+v", l)
	}
}

func TestAPasswordChangeIsLoggedAsChangedNeverAsAValue(t *testing.T) {
	e := auditEnv(t)
	e.as("admin", "PUT", "/api/users/vi", `{"password":"brand new password","role":"analyst"}`)
	l := find(e.auditLines(), "PUT /api/users/{name}")
	if l == nil || !strings.Contains(l.Detail, "password=changed") || !strings.Contains(l.Detail, "role=analyst") {
		t.Fatalf("line: %+v", l)
	}
	if strings.Contains(e.auditRaw(), "brand new password") {
		t.Error("the new password is in the audit log")
	}
}

func TestOnlyWhoMayReadTheAuditLogCan(t *testing.T) {
	e := auditEnv(t)
	if w := e.as("vi", "GET", "/api/audit", ""); !isForbidden(w) {
		t.Errorf("viewer: %d", w.Code)
	}
	e.as("admin", "POST", "/api/users", `{"name":"newbie","role":"viewer","password":"long enough pw"}`)
	w := e.as("an", "GET", "/api/audit?user=admin&result=ok", "")
	if w.Code != 200 {
		t.Fatalf("analyst: %d %s", w.Code, w.Body)
	}
	var res struct {
		Entries []audit.Entry
		Enabled bool
	}
	if err := json.Unmarshal(w.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if !res.Enabled || len(res.Entries) == 0 {
		t.Errorf("entries: %+v", res)
	}
	for _, en := range res.Entries {
		if en.User != "admin" || en.Result != audit.ResultOK {
			t.Errorf("filter leaked %+v", en)
		}
	}
}

func TestBadFiltersAre400(t *testing.T) {
	e := auditEnv(t)
	for _, q := range []string{"result=maybe", "since=yesterday", "limit=-3", "limit=x"} {
		if w := e.as("admin", "GET", "/api/audit?"+q, ""); w.Code != 400 {
			t.Errorf("%s: %d", q, w.Code)
		}
	}
	if w := e.as("admin", "GET", "/api/audit/export?format=xml", ""); w.Code != 400 {
		t.Errorf("format: %d", w.Code)
	}
}

func TestExportAsCSVAndJSON(t *testing.T) {
	e := auditEnv(t)
	e.as("admin", "POST", "/api/users", `{"name":"newbie","role":"viewer","password":"long enough pw"}`)
	w := e.as("admin", "GET", "/api/audit/export?format=csv", "")
	if w.Code != 200 || !strings.HasPrefix(w.Body.String(), "ts,user,ip,action,target,result,detail") ||
		!strings.Contains(w.Header().Get("Content-Disposition"), "attachment") {
		t.Errorf("csv: %d %q %v", w.Code, w.Body.String(), w.Header())
	}
	w = e.as("admin", "GET", "/api/audit/export", "")
	var list []audit.Entry
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil || len(list) == 0 {
		t.Errorf("json: %v %q", err, w.Body.String())
	}
}

func TestWithoutAnAuditLogNothingBreaks(t *testing.T) {
	e := usersEnv(t) // no Audit in the config
	if w := e.as("admin", "POST", "/api/users", `{"name":"x2","role":"viewer","password":"long enough pw"}`); w.Code != http.StatusCreated {
		t.Errorf("post: %d", w.Code)
	}
	w := e.as("admin", "GET", "/api/audit", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"enabled":false`) {
		t.Errorf("list: %d %s", w.Code, w.Body)
	}
}
