package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// usersJSON holds one user per role; every password is "correct horse".
func usersJSON(disabledOp bool) string {
	d := "false"
	if disabledOp {
		d = "true"
	}
	u := func(name, role, extra string) string {
		return `{"name":"` + name + `","role":"` + role + `","hash":"` + hashOK + `"` + extra + `}`
	}
	return `{"users":[` + strings.Join([]string{
		u("admin", "admin", ""),
		u("admin2", "admin", ""),
		u("op", "operator", `,"disabled":`+d),
		u("an", "analyst", ""),
		u("vi", "viewer", ""),
		u("cu", "custom", `,"perms":["view","rules.edit"]`),
		u("off", "viewer", `,"disabled":true`),
	}, ",") + `]}`
}

// recorder is a ctl that logs its arguments and its stdin and refuses what a
// real one would refuse.
const recorder = `#!/bin/sh
{ printf 'ARGS %s\n' "$*"; if [ "$1" = users ]; then printf 'STDIN %s\n' "$(cat)"; fi; } >> "$(dirname "$0")/calls.log"
case "$*" in
"users remove admin2") echo "users: the last user who may manage users cannot be removed, disabled or demoted" >&2; exit 3 ;;
esac
echo ok
`

func usersEnv(t *testing.T) *env {
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
	})
}

func (e *env) loginAs(name string) ([]*http.Cookie, string) {
	e.t.Helper()
	w := e.do(req{method: "POST", path: "/api/login", body: `{"username":"` + name + `","password":"correct horse"}`})
	if w.Code != 200 {
		e.t.Fatalf("login %s: %d %s", name, w.Code, w.Body)
	}
	var session, csrf string
	for _, c := range w.Result().Cookies() {
		switch c.Name {
		case sessionCookie:
			session = c.Value
		case csrfCookie:
			csrf = c.Value
		}
	}
	return []*http.Cookie{{Name: sessionCookie, Value: session}}, csrf
}

func (e *env) as(name, method, path, body string) *httptest.ResponseRecorder {
	cookies, csrf := e.loginAs(name)
	return e.do(req{method: method, path: path, body: body, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
}

func (e *env) calls() string {
	b, _ := os.ReadFile(filepath.Join(e.dir, "calls.log"))
	return string(b)
}

func isForbidden(w *httptest.ResponseRecorder) bool {
	if w.Code != http.StatusForbidden {
		return false
	}
	var b struct{ Error string }
	_ = json.Unmarshal(w.Body.Bytes(), &b)
	return b.Error == "forbidden"
}

// Every route and the permission it needs, against every kind of user.
var routePerms = []struct {
	method, path, perm string
	stream             bool
}{
	{"GET", "/api/status", auth.PermView, false},
	{"GET", "/api/version", auth.PermView, false},
	{"POST", "/api/update", auth.PermUpdateManage, false},
	{"GET", "/api/update/job", auth.PermView, false},
	{"POST", "/api/components/suricata/restart", auth.PermComponentsCtl, false},
	{"POST", "/api/suricata/reload", auth.PermComponentsCtl, false},
	{"GET", "/api/config", auth.PermConfigsEdit, false},
	{"GET", "/api/config/suricata.yaml", auth.PermConfigsEdit, false},
	{"PUT", "/api/config/suricata.yaml", auth.PermConfigsEdit, false},
	{"POST", "/api/config/suricata.yaml/check", auth.PermConfigsEdit, false},
	{"POST", "/api/config/suricata.yaml/revert", auth.PermConfigsEdit, false},
	{"GET", "/api/rules/sources", auth.PermView, false},
	{"POST", "/api/rules/sources", auth.PermRulesEdit, false},
	{"POST", "/api/rules/update", auth.PermRulesEdit, false},
	{"GET", "/api/rules/search?q=x", auth.PermView, false},
	{"POST", "/api/rules/groups/x/enable", auth.PermRulesEdit, false},
	{"POST", "/api/rules/sid/1/enable", auth.PermRulesEdit, false},
	{"GET", "/api/metrics", auth.PermView, false},
	{"POST", "/api/tests/all", auth.PermTestsRun, false},
	{"GET", "/api/tests/last", auth.PermView, false},
	{"GET", "/api/alerts", auth.PermView, false},
	{"GET", "/api/iface", auth.PermView, false},
	{"POST", "/api/iface/add", auth.PermSettingsEdit, false},
	{"GET", "/api/settings", auth.PermView, false},
	{"POST", "/api/settings/check", auth.PermSettingsEdit, false},
	{"POST", "/api/settings/apply", auth.PermSettingsEdit, false},
	{"PUT", "/api/settings/secret/GRAFANA_PASSWORD", auth.PermSettingsEdit, false},
	{"GET", "/api/settings/job", auth.PermView, false},
	{"GET", "/api/mode", auth.PermView, false},
	{"POST", "/api/mode", auth.PermIPSManage, false},
	{"POST", "/api/mode/confirm", auth.PermIPSManage, false},
	{"GET", "/api/eve", auth.PermView, false},
	{"GET", "/api/eve/stream", auth.PermView, true},
	{"GET", "/api/logs/suricata", auth.PermView, false},
	{"GET", "/api/logs/suricata/stream", auth.PermView, true},
	{"GET", "/api/users", auth.PermUsersManage, false},
	{"POST", "/api/users", auth.PermUsersManage, false},
	{"PUT", "/api/users/vi", auth.PermUsersManage, false},
	{"DELETE", "/api/users/vi", auth.PermUsersManage, false},
}

func TestEveryRouteAndEveryRole(t *testing.T) {
	e := usersEnv(t)
	list, err := (&auth.Users{File: filepath.Join(e.dir, "users.json")}).List()
	if err != nil {
		t.Fatal(err)
	}
	for _, u := range list {
		if u.Disabled {
			continue
		}
		cookies, csrf := e.loginAs(u.Name)
		for _, rt := range routePerms {
			hdr := map[string]string{"X-CSRF-Token": csrf}
			if rt.stream && u.Has(rt.perm) {
				continue // a stream stays open for an allowed user
			}
			w := e.do(req{method: rt.method, path: rt.path, body: `{}`, cookies: cookies, headers: hdr})
			if got, want := isForbidden(w), !u.Has(rt.perm); got != want {
				t.Errorf("%s (%s) %s %s: forbidden=%v, want %v (status %d)", u.Name, u.Role, rt.method, rt.path, got, want, w.Code)
			}
		}
	}
}

// A route added without a permission would be open to a viewer: only these
// handlers may use plain authed (any signed-in user).
func TestNoRouteIsWithoutAPermission(t *testing.T) {
	src, err := os.ReadFile("api.go")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`s\.authed\(s\.(\w+)\)`)
	allowed := map[string]bool{"logout": true, "me": true, "mePassword": true}
	for _, m := range re.FindAllStringSubmatch(string(src), -1) {
		if !allowed[m[1]] {
			t.Errorf("route handler %s uses authed without a permission", m[1])
		}
	}
}

func TestMeSaysWhoYouAre(t *testing.T) {
	e := usersEnv(t)
	w := e.as("cu", "GET", "/api/me", "")
	var me userView
	if err := json.Unmarshal(w.Body.Bytes(), &me); err != nil {
		t.Fatal(err)
	}
	if me.Name != "cu" || me.Role != "custom" || len(me.Perms) != 2 {
		t.Errorf("me = %+v", me)
	}
	if strings.Contains(w.Body.String(), "argon2") {
		t.Error("a hash in /api/me")
	}
}

func TestLoginWrongUserAndWrongPasswordLookTheSame(t *testing.T) {
	e := usersEnv(t)
	a := e.do(req{method: "POST", path: "/api/login", body: `{"username":"nobody","password":"correct horse"}`, remote: "192.168.1.20:1"})
	b := e.do(req{method: "POST", path: "/api/login", body: `{"username":"admin","password":"nope"}`, remote: "192.168.1.21:1"})
	c := e.do(req{method: "POST", path: "/api/login", body: `{"username":"off","password":"correct horse"}`, remote: "192.168.1.22:1"})
	for _, w := range []*httptest.ResponseRecorder{a, b, c} {
		if w.Code != 401 {
			t.Fatalf("status %d, want 401", w.Code)
		}
	}
	if a.Body.String() != b.Body.String() || b.Body.String() != c.Body.String() {
		t.Errorf("answers differ: %q %q %q", a.Body, b.Body, c.Body)
	}
}

func TestLoginWithoutUsernameIsAdmin(t *testing.T) {
	e := usersEnv(t)
	w := e.do(req{method: "POST", path: "/api/login", body: `{"password":"correct horse"}`})
	if w.Code != 200 {
		t.Fatalf("login: %d", w.Code)
	}
}

func TestADisabledUserIsCutOffAtOnce(t *testing.T) {
	e := usersEnv(t)
	cookies, _ := e.loginAs("op")
	if w := e.do(req{method: "GET", path: "/api/me", cookies: cookies}); w.Code != 200 {
		t.Fatalf("before: %d", w.Code)
	}
	if err := os.WriteFile(filepath.Join(e.dir, "users.json"), []byte(usersJSON(true)), 0o640); err != nil {
		t.Fatal(err)
	}
	if w := e.do(req{method: "GET", path: "/api/me", cookies: cookies}); w.Code != 401 {
		t.Errorf("after disabling: %d, want 401", w.Code)
	}
}

func TestUsersListHasNoHash(t *testing.T) {
	e := usersEnv(t)
	w := e.as("admin", "GET", "/api/users", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), "argon2") || strings.Contains(w.Body.String(), "hash") {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}

func TestCreateUserPutsThePasswordOnStdinNotInArguments(t *testing.T) {
	e := usersEnv(t)
	w := e.as("admin", "POST", "/api/users", `{"name":"newbie","role":"custom","perms":["view","tests.run"],"password":"s3cret-pass-word"}`)
	if w.Code != http.StatusCreated {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	calls := e.calls()
	if !strings.Contains(calls, "ARGS users add newbie custom --perms view,tests.run") {
		t.Errorf("calls: %s", calls)
	}
	if !strings.Contains(calls, "STDIN s3cret-pass-word") {
		t.Errorf("the password did not reach stdin: %s", calls)
	}
	if strings.Contains(strings.ReplaceAll(calls, "STDIN s3cret-pass-word", ""), "s3cret-pass-word") {
		t.Errorf("the password is in an argument: %s", calls)
	}
}

func TestCreateUserChecksItsInput(t *testing.T) {
	e := usersEnv(t)
	for name, body := range map[string]string{
		"bad name":      `{"name":"Bad Name","role":"viewer","password":"long enough pw"}`,
		"bad role":      `{"name":"bob","role":"boss","password":"long enough pw"}`,
		"short pw":      `{"name":"bob","role":"viewer","password":"short"}`,
		"custom empty":  `{"name":"bob","role":"custom","password":"long enough pw"}`,
		"unknown perm":  `{"name":"bob","role":"custom","perms":["fly"],"password":"long enough pw"}`,
		"newline in pw": `{"name":"bob","role":"viewer","password":"long enough\npw"}`,
	} {
		if w := e.as("admin", "POST", "/api/users", body); w.Code != 400 {
			t.Errorf("%s: %d, want 400", name, w.Code)
		}
	}
	if e.calls() != "" {
		t.Errorf("ctl was called: %s", e.calls())
	}
}

func TestChangingARoleEndsThatUsersSessions(t *testing.T) {
	e := usersEnv(t)
	opCookies, _ := e.loginAs("op")
	w := e.as("admin", "PUT", "/api/users/op", `{"role":"viewer"}`)
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ARGS users role op viewer") {
		t.Errorf("calls: %s", e.calls())
	}
	if w := e.do(req{method: "GET", path: "/api/status", cookies: opCookies}); w.Code != 401 {
		t.Errorf("old session: %d, want 401", w.Code)
	}
}

func TestOwnAccountCannotBeRemovedOrDisabledAndTheLastAdminIsGuardedByCtl(t *testing.T) {
	e := usersEnv(t)
	if w := e.as("admin", "DELETE", "/api/users/admin", ""); w.Code != 409 {
		t.Errorf("remove self: %d", w.Code)
	}
	if w := e.as("admin", "PUT", "/api/users/admin", `{"disabled":true}`); w.Code != 409 {
		t.Errorf("disable self: %d", w.Code)
	}
	w := e.as("admin", "DELETE", "/api/users/admin2", "")
	if w.Code != 409 || !strings.Contains(w.Body.String(), "last user") {
		t.Errorf("ctl refusal: %d %s", w.Code, w.Body)
	}
}

func TestOwnPasswordNeedsTheCurrentOne(t *testing.T) {
	e := usersEnv(t)
	if w := e.as("vi", "POST", "/api/me/password", `{"current":"wrong","new":"brand new password"}`); w.Code != 403 {
		t.Errorf("wrong current: %d", w.Code)
	}
	if e.calls() != "" {
		t.Errorf("ctl was called: %s", e.calls())
	}
	cookies, csrf := e.loginAs("vi")
	w := e.do(req{method: "POST", path: "/api/me/password", body: `{"current":"correct horse","new":"brand new password"}`, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ARGS users passwd vi") || !strings.Contains(e.calls(), "STDIN brand new password") {
		t.Errorf("calls: %s", e.calls())
	}
	if w := e.do(req{method: "GET", path: "/api/me", cookies: cookies}); w.Code != 401 {
		t.Errorf("session after the change: %d, want 401", w.Code)
	}
}
