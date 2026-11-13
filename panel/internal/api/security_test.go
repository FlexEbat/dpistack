package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/audit"
	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// securityScript stands in for `tokens ...` and `security check`: it logs its
// arguments and answers like the verbs do.
const securityScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
case "$1 $2" in
"tokens create") echo '{"id":"abcd1234","token":"dpt_SECRETSECRETSECRETSECRETSECRETSECRETSECRE","expires":"2030-01-01T00:00:00Z"}' ;;
"security check") echo '{"ts":"2026-01-01T00:00:00Z","checks":[{"id":"tls","level":"ok","title":"t","detail":"d","fix":""}],"counts":{"ok":1,"warn":0,"crit":0,"na":0}}' ;;
esac
[ -f "$dir/REFUSE" ] && { echo "dpistack: tokens: the scope admin holds more than an may do" >&2; exit 5; }
exit 0
`

const (
	secRead     = "dpt_" + "readreadreadreadreadreadreadreadreadread1" // owner an, read
	secViewer   = "dpt_" + "viewerviewerviewerviewerviewerviewerview2" // owner admin, viewer role
	secAdmin    = "dpt_" + "adminadminadminadminadminadminadminadmi3"  // owner admin, admin role
	secExpired  = "dpt_" + "expiredexpiredexpiredexpiredexpiredexp4"   // owner an, expired
	secDisabled = "dpt_" + "disableddisableddisableddisableddisab5"    // owner off (a disabled account)
)

func tokenRow(id, name, user, scope, secret, expires string) string {
	return `{"id":"` + id + `","name":"` + name + `","user":"` + user + `","scope":"` + scope + `","hash":"` + auth.HashToken(secret) + `","created":"2023-11-01T00:00:00Z","expires":"` + expires + `"}`
}

func securityEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		tokens := filepath.Join(dir, "api-tokens.json")
		doc := `{"tokens":[` + strings.Join([]string{
			tokenRow("11111111", "reader", "an", "read", secRead, "2030-01-01T00:00:00Z"),
			tokenRow("22222222", "viewer-of-admin", "admin", "viewer", secViewer, "2030-01-01T00:00:00Z"),
			tokenRow("33333333", "full", "admin", "admin", secAdmin, "2030-01-01T00:00:00Z"),
			tokenRow("44444444", "old", "an", "read", secExpired, "2023-01-01T00:00:00Z"),
			tokenRow("55555555", "ghost", "off", "read", secDisabled, "2030-01-01T00:00:00Z"),
		}, ",") + `]}`
		if err := os.WriteFile(tokens, []byte(doc), 0o640); err != nil {
			t.Fatal(err)
		}
		c.TokensFile = tokens
		script := filepath.Join(dir, "ctl")
		if err := os.WriteFile(script, []byte(securityScript), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: script}
		c.Audit = &audit.Log{Path: filepath.Join(dir, "audit.jsonl")}
	})
}

func (e *env) bearer(secret, method, path, body string) *httptest.ResponseRecorder {
	return e.do(req{method: method, path: path, body: body, headers: map[string]string{"Authorization": "Bearer " + secret}})
}

func jsonOf(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatalf("not JSON: %s", w.Body)
	}
	return m
}

// ---- API tokens as a way in ----

func TestBearerTokenActsAsItsOwnerWithoutCSRF(t *testing.T) {
	e := securityEnv(t)
	w := e.bearer(secRead, "GET", "/api/me", "")
	if w.Code != 200 {
		t.Fatalf("a live token: %d %s", w.Code, w.Body)
	}
	if m := jsonOf(t, w); m["name"] != "an" {
		t.Errorf("acts as the owner: %v", m)
	}
	// the scheme word is case-insensitive
	w = e.do(req{method: "GET", path: "/api/me", headers: map[string]string{"Authorization": "bearer " + secRead}})
	if w.Code != 200 {
		t.Errorf("lower case scheme: %d", w.Code)
	}
}

func TestReadTokenCannotChangeAnything(t *testing.T) {
	e := securityEnv(t)
	w := e.bearer(secRead, "POST", "/api/alert-center", `{"action":"ack","key":"sid:1"}`)
	if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "read only") {
		t.Errorf("a read token on a POST: %d %s", w.Code, w.Body)
	}
	if strings.Contains(e.calls(), "alerts") {
		t.Errorf("it never reached the verb: %q", e.calls())
	}
}

func TestRoleTokenHoldsTheRoleNotTheOwner(t *testing.T) {
	e := securityEnv(t)
	if w := e.bearer(secAdmin, "GET", "/api/users", ""); w.Code != 200 {
		t.Errorf("an admin token of an admin: %d %s", w.Code, w.Body)
	}
	w := e.bearer(secViewer, "GET", "/api/users", "")
	if !isForbidden(w) {
		t.Errorf("a viewer token of an admin is a viewer: %d %s", w.Code, w.Body)
	}
	if w := e.bearer(secViewer, "GET", "/api/me", ""); w.Code != 200 {
		t.Errorf("but it may read: %d", w.Code)
	}
}

func TestTokenThatIsExpiredUnknownOrOfADisabledOwnerIsRefused(t *testing.T) {
	e := securityEnv(t)
	for name, secret := range map[string]string{
		"expired":        secExpired,
		"disabled owner": secDisabled,
		"unknown":        "dpt_" + strings.Repeat("z", 43),
		"no prefix":      strings.Repeat("a", 47),
		"the hash":       auth.HashToken(secRead),
	} {
		if w := e.bearer(secret, "GET", "/api/me", ""); w.Code != http.StatusUnauthorized {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
	for _, h := range []string{"Basic abc", "Bearer", "Bearer ", "Token " + secRead, secRead} {
		w := e.do(req{method: "GET", path: "/api/me", headers: map[string]string{"Authorization": h}})
		if w.Code != http.StatusUnauthorized {
			t.Errorf("header %q: %d", h, w.Code)
		}
	}
}

func TestAnAuthorizationHeaderNeverFallsBackToACookie(t *testing.T) {
	e := securityEnv(t)
	cookies, csrf := e.loginAs("admin")
	w := e.do(req{method: "GET", path: "/api/me", cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf, "Authorization": "Bearer " + secRead + "x"}})
	if w.Code != http.StatusUnauthorized {
		t.Errorf("a wrong token with a good session is still a wrong token: %d", w.Code)
	}
}

func TestWrongTokensAreCountedRightOnesAreNot(t *testing.T) {
	e := securityEnv(t)
	for i := 0; i < 100; i++ {
		if w := e.bearer(secRead, "GET", "/api/me", ""); w.Code != 200 {
			t.Fatalf("a right token is never counted: call %d gave %d", i, w.Code)
		}
	}
	for i := 0; i < tokenFailMax; i++ {
		if w := e.bearer("dpt_"+strings.Repeat("q", 43), "GET", "/api/me", ""); w.Code != http.StatusUnauthorized {
			t.Fatalf("wrong token %d: %d", i, w.Code)
		}
	}
	w := e.bearer("dpt_"+strings.Repeat("q", 43), "GET", "/api/me", "")
	if w.Code != http.StatusTooManyRequests || w.Header().Get("Retry-After") == "" {
		t.Errorf("past the cap: %d", w.Code)
	}
	if w := e.bearer(secRead, "GET", "/api/me", ""); w.Code != http.StatusTooManyRequests {
		t.Errorf("a blocked address is blocked for a right token too: %d", w.Code)
	}
	// another address is not affected
	w = e.do(req{method: "GET", path: "/api/me", remote: "192.168.1.77:1", headers: map[string]string{"Authorization": "Bearer " + secRead}})
	if w.Code != 200 {
		t.Errorf("another address: %d", w.Code)
	}
	e.now = e.now.Add(loginWindow + time.Second)
	if w := e.bearer(secRead, "GET", "/api/me", ""); w.Code != 200 {
		t.Errorf("after the window: %d", w.Code)
	}
}

func TestTokenRequestsAreAuditedUnderTheTokensName(t *testing.T) {
	e := securityEnv(t)
	e.bearer(secRead, "POST", "/api/alert-center", `{}`) // refused: read only
	lines := e.auditLines()
	if len(lines) != 1 || lines[0].User != "token:reader" || lines[0].Result != audit.ResultDenied {
		t.Errorf("a refused token call is on the record, by name: %+v", lines)
	}
	if strings.Contains(e.auditRaw(), secRead) {
		t.Errorf("the secret is never in the audit log")
	}
}

func TestTokensAndSessionsAreNotManagedWithATokenButItsHistoryCanBeRead(t *testing.T) {
	e := securityEnv(t)
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/security/sessions"},
		{"GET", "/api/security/tokens"},
		{"POST", "/api/security/tokens"},
		{"DELETE", "/api/security/tokens/11111111"},
		{"POST", "/api/security/sessions/revoke-others"},
		{"POST", "/api/security/sessions/revoke-all"},
		{"DELETE", "/api/security/sessions/0123456789abcdef"},
	} {
		w := e.bearer(secAdmin, c.method, c.path, `{"name":"x","scope":"read","days":1}`)
		if w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "not an API token") {
			t.Errorf("%s %s with a token: %d %s", c.method, c.path, w.Code, w.Body)
		}
	}
	if strings.Contains(e.calls(), "tokens create") {
		t.Errorf("a token made no token: %q", e.calls())
	}
	if w := e.bearer(secAdmin, "GET", "/api/security/check", ""); w.Code != 200 {
		t.Errorf("the check may be read with a token: %d", w.Code)
	}
	if w := e.bearer(secAdmin, "GET", "/api/security/logins", ""); w.Code != 200 {
		t.Errorf("so may the history: %d", w.Code)
	}
}

func TestBearerNeedsTheTokensFile(t *testing.T) {
	e := setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users // no TokensFile
	})
	if w := e.bearer(secRead, "GET", "/api/me", ""); w.Code != http.StatusUnauthorized {
		t.Errorf("no tokens file, no tokens: %d", w.Code)
	}
}

// ---- sessions ----

func TestSessionsListOwnWithClientAndCurrentMark(t *testing.T) {
	e := securityEnv(t)
	login := func(name, ua, remote string) ([]*http.Cookie, string) {
		w := e.do(req{method: "POST", path: "/api/login", body: `{"username":"` + name + `","password":"correct horse"}`, remote: remote, headers: map[string]string{"User-Agent": ua}})
		if w.Code != 200 {
			t.Fatalf("login: %d", w.Code)
		}
		var s, c string
		for _, ck := range w.Result().Cookies() {
			if ck.Name == sessionCookie {
				s = ck.Value
			}
			if ck.Name == csrfCookie {
				c = ck.Value
			}
		}
		return []*http.Cookie{{Name: sessionCookie, Value: s}}, c
	}
	c1, csrf1 := login("an", "Firefox", "192.168.1.10:1")
	e.now = e.now.Add(time.Minute)
	c2, _ := login("an", "curl/8", "192.168.1.20:1")
	login("vi", "x", "192.168.1.30:1")
	w := e.do(req{method: "GET", path: "/api/security/sessions", cookies: c1, headers: map[string]string{"X-CSRF-Token": csrf1}})
	if w.Code != 200 {
		t.Fatalf("list: %d %s", w.Code, w.Body)
	}
	var out struct {
		Sessions []struct {
			Handle    string `json:"handle"`
			User      string `json:"user"`
			IP        string `json:"ip"`
			UserAgent string `json:"user_agent"`
			Current   bool   `json:"current"`
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || len(out.Sessions) != 2 {
		t.Fatalf("two of an's: %s", w.Body)
	}
	if out.Sessions[0].UserAgent != "curl/8" || out.Sessions[1].UserAgent != "Firefox" || out.Sessions[0].IP != "192.168.1.20" {
		t.Errorf("newest first, with where from: %+v", out.Sessions)
	}
	if out.Sessions[0].Current || !out.Sessions[1].Current {
		t.Errorf("the one asking is marked: %+v", out.Sessions)
	}
	if strings.Contains(w.Body.String(), c1[0].Value) || strings.Contains(w.Body.String(), c2[0].Value) {
		t.Errorf("a session id is never in the answer")
	}
}

func TestEndingASession(t *testing.T) {
	e := securityEnv(t)
	c1, csrf1 := e.loginAs("an")
	c2, csrf2 := e.loginAs("an")
	cv, csrfv := e.loginAs("vi")
	h2 := auth.Handle(c2[0].Value)
	hv := auth.Handle(cv[0].Value)
	call := func(c []*http.Cookie, csrf, method, path string) *httptest.ResponseRecorder {
		return e.do(req{method: method, path: path, cookies: c, headers: map[string]string{"X-CSRF-Token": csrf}})
	}
	if w := call(c1, csrf1, "DELETE", "/api/security/sessions/"+hv); w.Code != http.StatusNotFound {
		t.Errorf("someone else's session: %d", w.Code)
	}
	if w := call(cv, csrfv, "GET", "/api/me"); w.Code != 200 {
		t.Errorf("vi is untouched: %d", w.Code)
	}
	for _, bad := range []string{"zz", "0123", strings.Repeat("g", 16)} {
		if w := call(c1, csrf1, "DELETE", "/api/security/sessions/"+bad); w.Code != http.StatusBadRequest && w.Code != http.StatusNotFound {
			t.Errorf("handle %q: %d", bad, w.Code)
		}
	}
	if w := call(c1, csrf1, "DELETE", "/api/security/sessions/"+h2); w.Code != 200 {
		t.Fatalf("own session: %d %s", w.Code, w.Body)
	}
	if w := call(c2, csrf2, "GET", "/api/me"); w.Code != http.StatusUnauthorized {
		t.Errorf("the ended session is dead: %d", w.Code)
	}
	if w := call(c1, csrf1, "DELETE", "/api/security/sessions/"+h2); w.Code != http.StatusNotFound {
		t.Errorf("twice: %d", w.Code)
	}
	if w := call(c1, csrf1, "DELETE", "/api/security/sessions/"+h2); w.Code == 200 {
		t.Errorf("never ok twice")
	}
}

func TestEndingTheOtherSessions(t *testing.T) {
	e := securityEnv(t)
	c1, csrf1 := e.loginAs("an")
	c2, csrf2 := e.loginAs("an")
	c3, csrf3 := e.loginAs("an")
	cv, csrfv := e.loginAs("vi")
	w := e.do(req{method: "POST", path: "/api/security/sessions/revoke-others", cookies: c2, headers: map[string]string{"X-CSRF-Token": csrf2}})
	if w.Code != 200 || jsonOf(t, w)["ended"] != float64(2) {
		t.Fatalf("others: %d %s", w.Code, w.Body)
	}
	for name, c := range map[string]struct {
		cookies []*http.Cookie
		csrf    string
		want    int
	}{"c1": {c1, csrf1, 401}, "c2": {c2, csrf2, 200}, "c3": {c3, csrf3, 401}, "vi": {cv, csrfv, 200}} {
		if w := e.do(req{method: "GET", path: "/api/me", cookies: c.cookies, headers: map[string]string{"X-CSRF-Token": c.csrf}}); w.Code != c.want {
			t.Errorf("%s: %d, want %d", name, w.Code, c.want)
		}
	}
}

func TestSigningEveryoneOut(t *testing.T) {
	e := securityEnv(t)
	ca, csrfa := e.loginAs("admin")
	cn, csrfn := e.loginAs("an")
	if w := e.do(req{method: "POST", path: "/api/security/sessions/revoke-all", cookies: cn, headers: map[string]string{"X-CSRF-Token": csrfn}}); !isForbidden(w) {
		t.Errorf("an analyst may not: %d", w.Code)
	}
	if w := e.do(req{method: "GET", path: "/api/security/sessions?all=1", cookies: cn, headers: map[string]string{"X-CSRF-Token": csrfn}}); !isForbidden(w) {
		t.Errorf("nor list everyone's: %d", w.Code)
	}
	w := e.do(req{method: "GET", path: "/api/security/sessions?all=1", cookies: ca, headers: map[string]string{"X-CSRF-Token": csrfa}})
	if w.Code != 200 || strings.Count(w.Body.String(), `"handle"`) != 2 {
		t.Errorf("an admin lists all: %d %s", w.Code, w.Body)
	}
	w = e.do(req{method: "POST", path: "/api/security/sessions/revoke-all", cookies: ca, headers: map[string]string{"X-CSRF-Token": csrfa}})
	if w.Code != 200 || jsonOf(t, w)["ended"] != float64(2) {
		t.Fatalf("revoke all: %d %s", w.Code, w.Body)
	}
	cleared := 0
	for _, c := range w.Result().Cookies() {
		if c.MaxAge < 0 {
			cleared++
		}
	}
	if cleared != 2 {
		t.Errorf("the cookies of this browser are cleared: %d", cleared)
	}
	for name, c := range map[string]struct {
		cookies []*http.Cookie
		csrf    string
	}{"admin": {ca, csrfa}, "an": {cn, csrfn}} {
		if w := e.do(req{method: "GET", path: "/api/me", cookies: c.cookies, headers: map[string]string{"X-CSRF-Token": c.csrf}}); w.Code != http.StatusUnauthorized {
			t.Errorf("%s is signed out: %d", name, w.Code)
		}
	}
	if n := e.auditCount("ended all"); n != 1 {
		t.Errorf("audited once: %d", n)
	}
}

func (e *env) auditCount(detail string) int {
	n := 0
	for _, l := range e.auditLines() {
		if strings.Contains(l.Detail, detail) {
			n++
		}
	}
	return n
}

// ---- tokens page ----

func TestTokenListIsOwnAndHasNoHash(t *testing.T) {
	e := securityEnv(t)
	w := e.as("an", "GET", "/api/security/tokens", "")
	if w.Code != 200 {
		t.Fatalf("list: %d %s", w.Code, w.Body)
	}
	if strings.Contains(w.Body.String(), "hash") || strings.Contains(w.Body.String(), auth.HashToken(secRead)) {
		t.Errorf("no hash: %s", w.Body)
	}
	m := jsonOf(t, w)["tokens"].([]any)
	if len(m) != 2 {
		t.Fatalf("an owns two: %v", m)
	}
	byName := map[string]map[string]any{}
	for _, x := range m {
		byName[x.(map[string]any)["name"].(string)] = x.(map[string]any)
	}
	if byName["reader"]["expired"] != false || byName["old"]["expired"] != true || byName["reader"]["scope"] != "read" {
		t.Errorf("flags: %v", byName)
	}
	if _, ok := byName["reader"]["last_used"]; ok {
		t.Errorf("never used yet")
	}
	e.bearer(secRead, "GET", "/api/me", "")
	w = e.as("an", "GET", "/api/security/tokens", "")
	if !strings.Contains(w.Body.String(), "last_used") {
		t.Errorf("used now: %s", w.Body)
	}
}

func TestTokenListOfEveryoneIsForUsersManagers(t *testing.T) {
	e := securityEnv(t)
	if w := e.as("an", "GET", "/api/security/tokens?all=1", ""); !isForbidden(w) {
		t.Errorf("an analyst: %d", w.Code)
	}
	w := e.as("admin", "GET", "/api/security/tokens?all=1", "")
	if w.Code != 200 || len(jsonOf(t, w)["tokens"].([]any)) != 5 {
		t.Errorf("an admin sees all five: %d %s", w.Code, w.Body)
	}
	w = e.as("admin", "GET", "/api/security/tokens", "")
	if len(jsonOf(t, w)["tokens"].([]any)) != 2 {
		t.Errorf("without all: only own two: %s", w.Body)
	}
}

func TestTokenCreateRunsTheVerbAsTheSessionUserAndAuditsNoSecret(t *testing.T) {
	e := securityEnv(t)
	w := e.as("an", "POST", "/api/security/tokens", `{"name":"ci job","scope":"analyst","days":30}`)
	if w.Code != 200 {
		t.Fatalf("create: %d %s", w.Code, w.Body)
	}
	if m := jsonOf(t, w); m["id"] != "abcd1234" || !strings.HasPrefix(m["token"].(string), "dpt_") {
		t.Errorf("the secret comes back once: %v", m)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Errorf("never cached: %q", w.Header().Get("Cache-Control"))
	}
	if !strings.Contains(e.calls(), "tokens create --json --user an --name ci job --scope analyst --days 30\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	raw := e.auditRaw()
	if strings.Contains(raw, "SECRET") || !strings.Contains(raw, "create ci job analyst") {
		t.Errorf("the audit line says what, never the secret: %s", raw)
	}
}

func TestTokenCreateRefusesBadInputBeforeTheVerb(t *testing.T) {
	e := securityEnv(t)
	for name, body := range map[string]string{
		"no name":       `{"scope":"read","days":30}`,
		"upper name":    `{"name":"CI","scope":"read","days":30}`,
		"dash first":    `{"name":"-x","scope":"read","days":30}`,
		"long name":     `{"name":"` + strings.Repeat("a", 33) + `","scope":"read","days":30}`,
		"bad scope":     `{"name":"x","scope":"root","days":30}`,
		"custom scope":  `{"name":"x","scope":"custom","days":30}`,
		"no scope":      `{"name":"x","days":30}`,
		"zero days":     `{"name":"x","scope":"read","days":0}`,
		"366 days":      `{"name":"x","scope":"read","days":366}`,
		"no days":       `{"name":"x","scope":"read"}`,
		"negative days": `{"name":"x","scope":"read","days":-1}`,
		"not json":      `{`,
		"wrong shape":   `{"name":1}`,
	} {
		if w := e.as("an", "POST", "/api/security/tokens", body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	if strings.Contains(e.calls(), "tokens create") {
		t.Errorf("a refused request reached the verb: %q", e.calls())
	}
}

func TestTokenCreateVerbRefusalIsABadRequest(t *testing.T) {
	e := securityEnv(t)
	if err := os.WriteFile(filepath.Join(e.dir, "REFUSE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	w := e.as("an", "POST", "/api/security/tokens", `{"name":"x","scope":"admin","days":30}`)
	if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "more than an may do") {
		t.Errorf("exit 5: %d %s", w.Code, w.Body)
	}
}

func TestTokenRevoke(t *testing.T) {
	e := securityEnv(t)
	if w := e.as("an", "DELETE", "/api/security/tokens/22222222", ""); w.Code != http.StatusNotFound {
		t.Errorf("someone else's token: %d", w.Code)
	}
	if w := e.as("an", "DELETE", "/api/security/tokens/99999999", ""); w.Code != http.StatusNotFound {
		t.Errorf("an unknown token looks the same: %d", w.Code)
	}
	for _, bad := range []string{"xyz", "1234567", "ABCDEF12", "123456789"} {
		if w := e.as("an", "DELETE", "/api/security/tokens/"+bad, ""); w.Code != http.StatusBadRequest {
			t.Errorf("id %q: %d", bad, w.Code)
		}
	}
	if strings.Contains(e.calls(), "tokens revoke") {
		t.Errorf("nothing reached the verb yet: %q", e.calls())
	}
	if w := e.as("an", "DELETE", "/api/security/tokens/11111111", ""); w.Code != 200 {
		t.Fatalf("own token: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "tokens revoke 11111111 --user an\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	if w := e.as("admin", "DELETE", "/api/security/tokens/22222222", ""); w.Code != 200 {
		t.Fatalf("an admin may end any: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "tokens revoke 22222222 --user admin\n") {
		t.Errorf("the owner goes to the verb: %q", e.calls())
	}
}

// ---- sign in history and the check ----

func TestLoginHistoryIsOwnWithResultsAndNewestFirst(t *testing.T) {
	e := securityEnv(t)
	e.do(req{method: "POST", path: "/api/login", body: `{"username":"an","password":"wrong"}`, remote: "192.168.1.50:1"})
	e.now = e.now.Add(time.Minute)
	e.loginAs("an")
	e.loginAs("vi")
	w := e.as("an", "GET", "/api/security/logins", "")
	if w.Code != 200 {
		t.Fatalf("logins: %d %s", w.Code, w.Body)
	}
	var out struct {
		Logins []loginView
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if len(out.Logins) != 3 {
		t.Fatalf("an signed in twice (once more by as) and failed once: %+v", out.Logins)
	}
	if out.Logins[len(out.Logins)-1].Result != "denied" || out.Logins[len(out.Logins)-1].IP != "192.168.1.50" {
		t.Errorf("the wrong password is on the record, with where from: %+v", out.Logins)
	}
	for _, l := range out.Logins {
		if l.User != "an" {
			t.Errorf("only own: %+v", l)
		}
	}
	if strings.Contains(w.Body.String(), "wrong") {
		t.Errorf("never a password")
	}
}

func TestLoginHistoryOfOthersNeedsAuditView(t *testing.T) {
	e := securityEnv(t)
	e.loginAs("vi")
	if w := e.as("vi", "GET", "/api/security/logins?user=an", ""); !isForbidden(w) {
		t.Errorf("a viewer reads another's: %d", w.Code)
	}
	if w := e.as("vi", "GET", "/api/security/logins?all=1", ""); !isForbidden(w) {
		t.Errorf("a viewer reads all: %d", w.Code)
	}
	if w := e.as("an", "GET", "/api/security/logins?user=vi", ""); w.Code != 200 || !strings.Contains(w.Body.String(), `"user":"vi"`) {
		t.Errorf("an analyst has audit.view: %d %s", w.Code, w.Body)
	}
	w := e.as("an", "GET", "/api/security/logins?all=1", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"user":"vi"`) || !strings.Contains(w.Body.String(), `"user":"an"`) {
		t.Errorf("all: %d %s", w.Code, w.Body)
	}
}

func TestLoginHistoryLimitAndOtherActionsAreLeftOut(t *testing.T) {
	e := securityEnv(t)
	for i := 0; i < 5; i++ {
		e.loginAs("an")
	}
	e.as("an", "POST", "/api/security/sessions/revoke-others", "") // a different audited action
	w := e.as("an", "GET", "/api/security/logins?limit=2", "")
	if n := len(jsonOf(t, w)["logins"].([]any)); n != 2 {
		t.Errorf("limit 2: %d", n)
	}
	for _, q := range []string{"limit=0", "limit=201", "limit=x", "limit=-1"} {
		if w := e.as("an", "GET", "/api/security/logins?"+q, ""); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d", q, w.Code)
		}
	}
	w = e.as("an", "GET", "/api/security/logins?limit=200", "")
	for _, l := range jsonOf(t, w)["logins"].([]any) {
		if l.(map[string]any)["ts"] == nil {
			t.Errorf("an entry without a time")
		}
	}
}

func TestLoginHistoryWithoutAnAuditLogIsEmpty(t *testing.T) {
	e := setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
	})
	w := e.as("an", "GET", "/api/security/logins", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != `{"logins":[]}` {
		t.Errorf("no audit log: %d %s", w.Code, w.Body)
	}
}

func TestSecurityCheckPassesTheVerbJSONThrough(t *testing.T) {
	e := securityEnv(t)
	w := e.as("an", "GET", "/api/security/check", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"checks"`) {
		t.Fatalf("check: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "security check --json\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	if w := e.as("vi", "GET", "/api/security/check", ""); !isForbidden(w) {
		t.Errorf("a viewer has no audit.view: %d", w.Code)
	}
}
