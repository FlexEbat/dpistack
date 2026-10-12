package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// Hash of "correct horse" made by the argon2 CLI, see auth_test.go.
const hashOK = "$argon2id$v=19$m=16384,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$06P4n5MT+1p4xkEaN81bac/LFLj2y/TdZ8HFiBx7mOc"

const statusJSON = `{"components":[{"id":"suricata","runtime":"native","state":"active","enabled":true,"version":"8.0.7"}],"ndpi_plugin":"loaded"}`

const healthJSON = `{"ts":"2026-10-12T10:00:00Z","overall":"warn","checks":[{"id":"disk.free","status":"warn","value":"12","detail":"12% free","since":"2026-10-12T09:00:00Z"}]}`

type env struct {
	t       *testing.T
	dir     string
	handler http.Handler
	now     time.Time
}

type option func(*Config, string)

func setup(t *testing.T, opts ...option) *env {
	t.Helper()
	dir := t.TempDir()
	e := &env{t: t, dir: dir, now: time.Unix(1_700_000_000, 0)}

	write := func(name, content string, mode os.FileMode) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
		return p
	}
	policy, err := auth.NewPolicy("lan", "192.168.1.0/24")
	if err != nil {
		t.Fatal(err)
	}
	cfg := Config{
		Policy:     policy,
		AuthFile:   write("panel.auth", hashOK+"\n", 0o640),
		HealthFile: write("health.json", healthJSON, 0o644),
		Ctl:        &ctl.Runner{Path: write("ctl", "#!/bin/sh\nprintf '%s' '"+statusJSON+"'\n", 0o755)},
		Web:        fstest.MapFS{"index.html": {Data: []byte("<html>panel</html>")}},
		Now:        func() time.Time { return e.now },
	}
	for _, o := range opts {
		o(&cfg, dir)
	}
	e.handler = New(cfg)
	return e
}

type req struct {
	method, path, body string
	remote             string
	headers            map[string]string
	cookies            []*http.Cookie
}

func (e *env) do(r req) *httptest.ResponseRecorder {
	e.t.Helper()
	if r.remote == "" {
		r.remote = "192.168.1.10:40000"
	}
	hr := httptest.NewRequest(r.method, r.path, strings.NewReader(r.body))
	hr.RemoteAddr = r.remote
	if r.body != "" {
		hr.Header.Set("Content-Type", "application/json")
	}
	for k, v := range r.headers {
		hr.Header.Set(k, v)
	}
	for _, c := range r.cookies {
		hr.AddCookie(c)
	}
	w := httptest.NewRecorder()
	e.handler.ServeHTTP(w, hr)
	return w
}

// login returns the cookies and CSRF token of a fresh session.
func (e *env) login() ([]*http.Cookie, string) {
	e.t.Helper()
	w := e.do(req{method: "POST", path: "/api/login", body: `{"password":"correct horse"}`})
	if w.Code != 200 {
		e.t.Fatalf("login: %d %s", w.Code, w.Body)
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
	if session == "" || csrf == "" {
		e.t.Fatal("login set no cookies")
	}
	return []*http.Cookie{{Name: sessionCookie, Value: session}}, csrf
}

func errorText(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var b struct{ Error string }
	if err := json.Unmarshal(w.Body.Bytes(), &b); err != nil || b.Error == "" {
		t.Fatalf("not an error body: %q", w.Body)
	}
	return b.Error
}

// Criterion 1: no session, no /api/* except POST /api/login.
func TestAPIWithoutSessionIs401(t *testing.T) {
	e := setup(t)
	for _, r := range []req{
		{method: "GET", path: "/api/status"},
		{method: "POST", path: "/api/logout"},
		{method: "GET", path: "/api/config/suricata.yaml"},
		{method: "PUT", path: "/api/config/suricata.yaml"},
		{method: "GET", path: "/api/login"},
		{method: "GET", path: "/api/nonexistent"},
		{method: "GET", path: "/api/status", cookies: []*http.Cookie{{Name: sessionCookie, Value: "forged"}}},
	} {
		if w := e.do(r); w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s: %d, want 401", r.method, r.path, w.Code)
		}
	}
	if w := e.do(req{method: "GET", path: "/"}); w.Code != 200 {
		t.Errorf("login page itself must load: %d", w.Code)
	}
}

// Criterion 2.
func TestWrongPasswordIs401AndSixthAttemptIs429(t *testing.T) {
	e := setup(t)
	bad := req{method: "POST", path: "/api/login", body: `{"password":"nope"}`}
	for i := 1; i <= 5; i++ {
		if w := e.do(bad); w.Code != http.StatusUnauthorized {
			t.Fatalf("attempt %d: %d, want 401", i, w.Code)
		}
	}
	w := e.do(bad)
	if w.Code != http.StatusTooManyRequests || w.Header().Get("Retry-After") == "" {
		t.Fatalf("sixth attempt: %d retry-after %q", w.Code, w.Header().Get("Retry-After"))
	}
	right := req{method: "POST", path: "/api/login", body: `{"password":"correct horse"}`}
	if w := e.do(right); w.Code != http.StatusTooManyRequests {
		t.Errorf("a locked address must not log in even with the right password: %d", w.Code)
	}
	if w := e.do(req{method: "POST", path: "/api/login", body: `{"password":"nope"}`, remote: "192.168.1.11:1"}); w.Code != 401 {
		t.Errorf("another address is not locked: %d", w.Code)
	}
	e.now = e.now.Add(5*time.Minute + time.Second)
	if w := e.do(right); w.Code != 200 {
		t.Errorf("after the window: %d", w.Code)
	}
}

func TestLoginCookies(t *testing.T) {
	e := setup(t)
	w := e.do(req{method: "POST", path: "/api/login", body: `{"password":"correct horse"}`})
	var sess, csrf *http.Cookie
	for _, c := range w.Result().Cookies() {
		switch c.Name {
		case sessionCookie:
			sess = c
		case csrfCookie:
			csrf = c
		}
	}
	if sess == nil || !sess.HttpOnly || sess.SameSite != http.SameSiteStrictMode {
		t.Errorf("session cookie must be HttpOnly and SameSite=Strict: %+v", sess)
	}
	if csrf == nil || csrf.HttpOnly || csrf.SameSite != http.SameSiteStrictMode {
		t.Errorf("csrf cookie must be script-readable and SameSite=Strict: %+v", csrf)
	}
	if sess != nil && sess.MaxAge != 12*3600 {
		t.Errorf("session lifetime %d, want 12 hours", sess.MaxAge)
	}
}

func TestLoginRequiresJSON(t *testing.T) {
	e := setup(t)
	w := e.do(req{method: "POST", path: "/api/login", body: "password=correct+horse", headers: map[string]string{"Content-Type": "application/x-www-form-urlencoded"}})
	if w.Code != http.StatusUnsupportedMediaType {
		t.Errorf("form post: %d, want 415", w.Code)
	}
}

func TestLoginWithoutPasswordFile(t *testing.T) {
	e := setup(t, func(c *Config, dir string) { c.AuthFile = filepath.Join(dir, "absent") })
	w := e.do(req{method: "POST", path: "/api/login", body: `{"password":"x"}`})
	if w.Code != 500 || !strings.Contains(errorText(t, w), "пароль панели не задан") {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}

// Criterion 3.
func TestChangingRequestNeedsCSRFToken(t *testing.T) {
	e := setup(t)
	cookies, csrf := e.login()
	for name, h := range map[string]map[string]string{
		"missing": nil,
		"wrong":   {"X-CSRF-Token": "forged"},
	} {
		w := e.do(req{method: "POST", path: "/api/logout", cookies: cookies, headers: h})
		if w.Code != http.StatusForbidden {
			t.Errorf("%s token: %d, want 403", name, w.Code)
		}
	}
	if w := e.do(req{method: "GET", path: "/api/status", cookies: cookies}); w.Code != 200 {
		t.Errorf("GET needs no CSRF token: %d", w.Code)
	}
	if w := e.do(req{method: "POST", path: "/api/logout", cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}}); w.Code != 200 {
		t.Errorf("right token: %d", w.Code)
	}
	if w := e.do(req{method: "GET", path: "/api/status", cookies: cookies}); w.Code != 401 {
		t.Errorf("session must end at logout: %d", w.Code)
	}
}

func TestSessionExpiresAfter12Hours(t *testing.T) {
	e := setup(t)
	cookies, _ := e.login()
	e.now = e.now.Add(12*time.Hour - time.Minute)
	if w := e.do(req{method: "GET", path: "/api/status", cookies: cookies}); w.Code != 200 {
		t.Fatalf("inside 12 hours: %d", w.Code)
	}
	e.now = e.now.Add(2 * time.Minute)
	if w := e.do(req{method: "GET", path: "/api/status", cookies: cookies}); w.Code != 401 {
		t.Errorf("after 12 hours: %d", w.Code)
	}
}

// Criterion 4, through the HTTP layer.
func TestClientOutsideLANGets403(t *testing.T) {
	e := setup(t)
	for _, r := range []req{
		{method: "GET", path: "/", remote: "10.0.0.5:1"},
		{method: "POST", path: "/api/login", body: `{"password":"correct horse"}`, remote: "10.0.0.5:1"},
		{method: "GET", path: "/api/status", remote: "10.0.0.5:1", headers: map[string]string{"X-Forwarded-For": "192.168.1.10"}},
		{method: "GET", path: "/", remote: "127.0.0.1:1"},
	} {
		w := e.do(r)
		if w.Code != http.StatusForbidden {
			t.Errorf("%s %s from %s: %d, want 403", r.method, r.path, r.remote, w.Code)
		}
		errorText(t, w)
	}
}

func TestLocalhostModeAndForwardedHeader(t *testing.T) {
	policy, _ := auth.NewPolicy("localhost", "")
	e := setup(t, func(c *Config, _ string) { c.Policy = policy })
	if w := e.do(req{method: "GET", path: "/", remote: "127.0.0.1:1"}); w.Code != 200 {
		t.Errorf("loopback: %d", w.Code)
	}
	if w := e.do(req{method: "GET", path: "/", remote: "192.168.1.10:1"}); w.Code != 403 {
		t.Errorf("lan client in localhost mode: %d", w.Code)
	}
	if w := e.do(req{method: "GET", path: "/", remote: "127.0.0.1:1", headers: map[string]string{"X-Forwarded-For": "203.0.113.9"}}); w.Code != 403 {
		t.Errorf("forwarded stranger: %d", w.Code)
	}
}

func TestRateLimitUsesForwardedClient(t *testing.T) {
	policy, _ := auth.NewPolicy("nginx", "192.168.1.0/24")
	e := setup(t, func(c *Config, _ string) { c.Policy = policy })
	attempt := func(client string) int {
		return e.do(req{method: "POST", path: "/api/login", body: `{"password":"nope"}`, remote: "127.0.0.1:1",
			headers: map[string]string{"X-Forwarded-For": client}}).Code
	}
	for i := 0; i < 5; i++ {
		attempt("192.168.1.20")
	}
	if got := attempt("192.168.1.20"); got != 429 {
		t.Errorf("same client behind nginx: %d, want 429", got)
	}
	if got := attempt("192.168.1.21"); got != 401 {
		t.Errorf("other client behind nginx shares the cap: %d", got)
	}
}

// Criterion 5.
func TestStatusMergesCtlAndHealth(t *testing.T) {
	e := setup(t)
	cookies, _ := e.login()
	w := e.do(req{method: "GET", path: "/api/status", cookies: cookies})
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	var got struct {
		Components []struct{ ID, State, Version string }
		NDPIPlugin string `json:"ndpi_plugin"`
		Health     struct {
			Overall string
			Checks  []struct{ ID, Status string }
		}
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Components) != 1 || got.Components[0].ID != "suricata" || got.Components[0].State != "active" || got.Components[0].Version != "8.0.7" {
		t.Errorf("components: %+v", got.Components)
	}
	if got.NDPIPlugin != "loaded" || got.Health.Overall != "warn" || len(got.Health.Checks) != 1 || got.Health.Checks[0].ID != "disk.free" {
		t.Errorf("merged body: %s", w.Body)
	}
}

func TestStatusBeforeFirstHealthReport(t *testing.T) {
	e := setup(t, func(c *Config, dir string) { c.HealthFile = filepath.Join(dir, "absent.json") })
	cookies, _ := e.login()
	w := e.do(req{method: "GET", path: "/api/status", cookies: cookies})
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"health":null`) {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}

func TestUnavailableCtlGives502WithReadableText(t *testing.T) {
	for name, tc := range map[string]struct {
		script string // empty: the helper does not exist
		want   string
	}{
		"missing":   {"", "dpistack-ctl недоступен"},
		"exit code": {"#!/bin/sh\necho 'sudo: a password is required' >&2\nexit 1\n", "a password is required"},
		"not json":  {"#!/bin/sh\necho oops\n", "dpistack-ctl недоступен"},
	} {
		t.Run(name, func(t *testing.T) {
			e := setup(t, func(c *Config, dir string) {
				path := filepath.Join(dir, "ctl-"+strings.ReplaceAll(name, " ", "-"))
				if tc.script != "" {
					if err := os.WriteFile(path, []byte(tc.script), 0o755); err != nil {
						t.Fatal(err)
					}
				}
				c.Ctl = &ctl.Runner{Path: path}
			})
			cookies, _ := e.login()
			w := e.do(req{method: "GET", path: "/api/status", cookies: cookies})
			if w.Code != http.StatusBadGateway {
				t.Fatalf("%d, want 502", w.Code)
			}
			if text := errorText(t, w); !strings.Contains(text, tc.want) {
				t.Errorf("error text %q lacks %q", text, tc.want)
			}
		})
	}
}

func TestBrokenHealthFileGives502(t *testing.T) {
	e := setup(t, func(c *Config, dir string) {
		p := filepath.Join(dir, "broken.json")
		os.WriteFile(p, []byte("{"), 0o644)
		c.HealthFile = p
	})
	cookies, _ := e.login()
	if w := e.do(req{method: "GET", path: "/api/status", cookies: cookies}); w.Code != 502 {
		t.Errorf("%d, want 502", w.Code)
	}
}

// Criterion 6: there is no setting that opens the API. A server built from
// a bare config still answers 401 and cannot be logged into.
func TestNoConfigurationSwitchesLoginOff(t *testing.T) {
	policy, _ := auth.NewPolicy("localhost", "")
	h := New(Config{Policy: policy, Ctl: &ctl.Runner{Path: "/nonexistent"}})
	hr := httptest.NewRequest("GET", "/api/status", nil)
	hr.RemoteAddr = "127.0.0.1:1"
	w := httptest.NewRecorder()
	h.ServeHTTP(w, hr)
	if w.Code != 401 {
		t.Errorf("bare config: %d, want 401", w.Code)
	}
	hr = httptest.NewRequest("POST", "/api/login", strings.NewReader(`{"password":""}`))
	hr.RemoteAddr = "127.0.0.1:1"
	hr.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, hr)
	if w.Code == 200 {
		t.Error("an empty password must not log in")
	}
}

func TestSecurityHeaders(t *testing.T) {
	e := setup(t)
	w := e.do(req{method: "GET", path: "/api/status"})
	for _, h := range []string{"Content-Security-Policy", "X-Content-Type-Options", "X-Frame-Options", "Referrer-Policy"} {
		if w.Header().Get(h) == "" {
			t.Errorf("missing %s", h)
		}
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Error("API responses must not be cached")
	}
}
