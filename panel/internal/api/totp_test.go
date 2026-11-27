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
	"time"

	"github.com/pquerna/otp/totp"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

const testTOTPSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

// twoFactorEnv is usersEnv with a second factor on the account "an" (analyst):
// the secret above and ten recovery codes, of which the plain ones are
// returned.
func twoFactorEnv(t *testing.T) (*env, []string) {
	t.Helper()
	plain, hashes, err := auth.NewRecoveryCodes()
	if err != nil {
		t.Fatal(err)
	}
	hj, _ := json.Marshal(hashes)
	users := strings.Replace(usersJSON(false),
		`"name":"an","role":"analyst","hash":"`+hashOK+`"`,
		`"name":"an","role":"analyst","hash":"`+hashOK+`","totp":{"secret":"`+testTOTPSecret+`","recovery":`+string(hj)+`}`, 1)
	if users == usersJSON(false) {
		t.Fatal("the account an was not found in the test users")
	}
	e := setup(t, func(c *Config, dir string) {
		path := filepath.Join(dir, "users.json")
		if err := os.WriteFile(path, []byte(users), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = path
		script := filepath.Join(dir, "ctl")
		if err := os.WriteFile(script, []byte(recorder), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: script}
	})
	return e, plain
}

func (e *env) code() string {
	e.t.Helper()
	c, err := totp.GenerateCode(testTOTPSecret, e.now)
	if err != nil {
		e.t.Fatal(err)
	}
	return c
}

// passwordStep is the first step: it returns the ticket.
func (e *env) passwordStep(name, remote string) (string, *httptest.ResponseRecorder) {
	e.t.Helper()
	w := e.do(req{method: "POST", path: "/api/login", remote: remote, body: `{"username":"` + name + `","password":"correct horse"}`})
	var b struct {
		Ticket       string `json:"ticket"`
		TOTPRequired bool   `json:"totp_required"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &b)
	return b.Ticket, w
}

func (e *env) secondStep(ticket, field, value, remote string) *httptest.ResponseRecorder {
	e.t.Helper()
	return e.do(req{method: "POST", path: "/api/login/totp", remote: remote,
		body: `{"ticket":"` + ticket + `","` + field + `":"` + value + `"}`})
}

func sessionOf(w *httptest.ResponseRecorder) []*http.Cookie {
	for _, c := range w.Result().Cookies() {
		if c.Name == sessionCookie && c.Value != "" {
			return []*http.Cookie{{Name: sessionCookie, Value: c.Value}}
		}
	}
	return nil
}

// signIn makes a full sign-in of "an" and returns the session and the CSRF.
func (e *env) signIn(t *testing.T) ([]*http.Cookie, string) {
	t.Helper()
	ticket, _ := e.passwordStep("an", "")
	w := e.secondStep(ticket, "code", e.code(), "")
	if w.Code != 200 {
		t.Fatalf("second step: %d %s", w.Code, w.Body)
	}
	var csrf string
	for _, c := range w.Result().Cookies() {
		if c.Name == csrfCookie {
			csrf = c.Value
		}
	}
	return sessionOf(w), csrf
}

func TestRightPasswordAloneGivesNoSessionWhenTheAccountHasASecondFactor(t *testing.T) {
	e, _ := twoFactorEnv(t)
	ticket, w := e.passwordStep("an", "")
	if w.Code != 200 || ticket == "" {
		t.Fatalf("want 200 with a ticket, got %d %s", w.Code, w.Body)
	}
	if len(w.Result().Cookies()) != 0 {
		t.Fatalf("no cookie before the second factor, got %v", w.Result().Cookies())
	}
	if !strings.Contains(w.Body.String(), `"totp_required":true`) {
		t.Fatalf("the answer must say what is needed: %s", w.Body)
	}
	// An account without one signs in as before.
	if _, w := e.passwordStep("vi", ""); sessionOf(w) == nil {
		t.Fatalf("an account without a second factor must get its session at once: %s", w.Body)
	}
}

func TestGoodCodeMakesTheSession(t *testing.T) {
	e, _ := twoFactorEnv(t)
	cookies, _ := e.signIn(t)
	w := e.do(req{method: "GET", path: "/api/me", cookies: cookies})
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"name":"an"`) {
		t.Fatalf("the session must work: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(w.Body.String(), `"two_factor":true`) {
		t.Fatalf("/api/me must say the account has a second factor: %s", w.Body)
	}
}

func TestWrongCodeGivesNothingAndFiveWrongCodesKillTheTicket(t *testing.T) {
	e, _ := twoFactorEnv(t)
	ticket, _ := e.passwordStep("an", "")
	for i := 0; i < auth.TicketTries; i++ {
		w := e.secondStep(ticket, "code", "000000", "")
		if w.Code != 401 || sessionOf(w) != nil {
			t.Fatalf("try %d: want 401 and no session, got %d", i+1, w.Code)
		}
	}
	// The right code no longer helps: the person must start again.
	if w := e.secondStep(ticket, "code", e.code(), ""); w.Code != 401 {
		t.Fatalf("a dead ticket must not accept the right code, got %d", w.Code)
	}
	ticket, _ = e.passwordStep("an", "")
	if w := e.secondStep(ticket, "code", e.code(), ""); w.Code != 200 {
		t.Fatalf("a new ticket works, got %d", w.Code)
	}
}

func TestACodeIsGoodOnce(t *testing.T) {
	e, _ := twoFactorEnv(t)
	e.signIn(t)
	ticket, _ := e.passwordStep("an", "")
	if w := e.secondStep(ticket, "code", e.code(), ""); w.Code != 401 {
		t.Fatalf("the same code a second time must not be good, got %d", w.Code)
	}
	e.now = e.now.Add(auth.TOTPPeriod * time.Second)
	if w := e.secondStep(ticket, "code", e.code(), ""); w.Code != 200 {
		t.Fatalf("the code of the next period must be good, got %d %s", w.Code, w.Body)
	}
}

func TestTicketIsForTheAddressItWasGivenAndEnds(t *testing.T) {
	e, _ := twoFactorEnv(t)
	ticket, _ := e.passwordStep("an", "192.168.1.10:40000")
	if w := e.secondStep(ticket, "code", e.code(), "192.168.1.11:40000"); w.Code != 401 {
		t.Fatalf("another address must not use the ticket, got %d", w.Code)
	}
	e.now = e.now.Add(auth.TicketTTL + time.Second)
	if w := e.secondStep(ticket, "code", e.code(), "192.168.1.10:40000"); w.Code != 401 {
		t.Fatalf("an old ticket must not be good, got %d", w.Code)
	}
	if w := e.secondStep("made-up", "code", e.code(), ""); w.Code != 401 {
		t.Fatalf("a ticket that was never given must not be good, got %d", w.Code)
	}
}

func TestSecondFactorAttemptsAreCountedPerAddress(t *testing.T) {
	e, _ := twoFactorEnv(t)
	var last int
	for i := 0; i < totpLoginMax+3; i++ {
		ticket, _ := e.passwordStep("an", "192.168.1.40:1")
		last = e.secondStep(ticket, "code", "000000", "192.168.1.40:1").Code
		if i < totpLoginMax && last != 401 {
			t.Fatalf("attempt %d: want 401, got %d", i+1, last)
		}
	}
	if last != 429 {
		t.Fatalf("after %d wrong codes from one address the answer must be 429, got %d", totpLoginMax, last)
	}
	// Another address is not held back.
	ticket, _ := e.passwordStep("an", "192.168.1.41:1")
	if w := e.secondStep(ticket, "code", e.code(), "192.168.1.41:1"); w.Code != 200 {
		t.Fatalf("another address must still work, got %d", w.Code)
	}
}

func TestRecoveryCodeSignsInAndIsUsedUp(t *testing.T) {
	e, plain := twoFactorEnv(t)
	ticket, _ := e.passwordStep("an", "")
	w := e.secondStep(ticket, "recovery", strings.ToUpper(plain[2]), "")
	if w.Code != 200 || sessionOf(w) == nil {
		t.Fatalf("a recovery code must sign in: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(w.Body.String(), `"recovery_left":9`) {
		t.Fatalf("the answer must say how many are left: %s", w.Body)
	}
	log := e.calls()
	if !strings.Contains(log, "ARGS users totp-used an") || !strings.Contains(log, "STDIN "+auth.HashRecovery(plain[2])) {
		t.Fatalf("the code must be marked used through dpistack, with its hash on stdin:\n%s", log)
	}
	if strings.Contains(log, plain[2]) {
		t.Fatalf("the plain recovery code must never reach dpistack:\n%s", log)
	}
	ticket, _ = e.passwordStep("an", "")
	if w := e.secondStep(ticket, "recovery", "aaaaa-aaaaa", ""); w.Code != 401 {
		t.Fatalf("a wrong recovery code must not be good, got %d", w.Code)
	}
}

func TestUsersListSaysWhoHasASecondFactorAndNeverWhatItIs(t *testing.T) {
	e, plain := twoFactorEnv(t)
	w := e.as("admin", "GET", "/api/users", "")
	if w.Code != 200 {
		t.Fatalf("users: %d %s", w.Code, w.Body)
	}
	body := w.Body.String()
	for _, secret := range append([]string{testTOTPSecret, "totp", "recovery"}, plain...) {
		if strings.Contains(body, secret) {
			t.Fatalf("the user list must not hold %q: %s", secret, body)
		}
	}
	var out struct {
		Users []userView `json:"users"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	got := map[string]bool{}
	for _, u := range out.Users {
		got[u.Name] = u.TwoFactor
	}
	if !got["an"] || got["vi"] {
		t.Fatalf("an has a second factor and vi has not: %v", got)
	}
}

var recoveryShape = regexp.MustCompile(`^[a-z2-9]{5}-[a-z2-9]{5}$`)

func TestSettingUpTheSecondFactor(t *testing.T) {
	e := usersEnv(t)
	cookies, csrf := e.loginAs("vi")
	post := func(path, body string) *httptest.ResponseRecorder {
		return e.do(req{method: "POST", path: path, body: body, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
	}
	if w := post("/api/me/totp/enable", `{"code":"123456"}`); w.Code != 409 {
		t.Fatalf("enable without setup must be 409, got %d", w.Code)
	}
	if w := post("/api/me/totp/setup", `{"password":"wrong one"}`); w.Code != 403 {
		t.Fatalf("setup with a wrong password must be 403, got %d", w.Code)
	}
	w := post("/api/me/totp/setup", `{"password":"correct horse"}`)
	if w.Code != 200 {
		t.Fatalf("setup: %d %s", w.Code, w.Body)
	}
	var s struct{ Secret, URI, QR string }
	if err := json.Unmarshal(w.Body.Bytes(), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Secret) < 16 || !strings.HasPrefix(s.URI, "otpauth://totp/dpistack:vi?") || !strings.Contains(s.URI, "secret="+s.Secret) || !strings.HasPrefix(s.QR, "data:image/png;base64,") {
		t.Fatalf("setup must give a secret, an otpauth URI and a QR code: %+v", s)
	}
	if strings.Contains(e.calls(), "totp-set") {
		t.Fatal("nothing may be stored before the first code")
	}
	if w := post("/api/me/totp/enable", `{"code":"000000"}`); w.Code != 422 {
		t.Fatalf("a wrong code must be 422, got %d", w.Code)
	}
	code, err := totp.GenerateCode(s.Secret, e.now)
	if err != nil {
		t.Fatal(err)
	}
	w = post("/api/me/totp/enable", `{"code":"`+code+`"}`)
	if w.Code != 200 {
		t.Fatalf("enable: %d %s", w.Code, w.Body)
	}
	var en struct {
		Recovery []string `json:"recovery"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &en)
	if len(en.Recovery) != auth.RecoveryCount {
		t.Fatalf("want %d recovery codes, got %v", auth.RecoveryCount, en.Recovery)
	}
	log := e.calls()
	if !strings.Contains(log, "ARGS users totp-set vi") || !strings.Contains(log, `"secret":"`+s.Secret+`"`) {
		t.Fatalf("the secret must go to dpistack on stdin:\n%s", log)
	}
	for _, c := range en.Recovery {
		if !recoveryShape.MatchString(c) {
			t.Errorf("recovery code %q has the wrong shape", c)
		}
		if strings.Contains(log, c) {
			t.Errorf("the plain recovery code %q must never reach dpistack", c)
		}
		if !strings.Contains(log, auth.HashRecovery(c)) {
			t.Errorf("the hash of %q must be stored", c)
		}
	}
	if strings.Contains(strings.SplitN(log, "ARGS users totp-set vi", 2)[0], s.Secret) {
		t.Error("the secret must not be in an argument")
	}
	// A secret that was asked for once is used once.
	if w := post("/api/me/totp/enable", `{"code":"`+code+`"}`); w.Code != 409 {
		t.Fatalf("a second enable must be 409, got %d", w.Code)
	}
}

func TestSetupIsRefusedWhenTheSecondFactorIsOn(t *testing.T) {
	e, _ := twoFactorEnv(t)
	cookies, csrf := e.signIn(t)
	w := e.do(req{method: "POST", path: "/api/me/totp/setup", body: `{"password":"correct horse"}`, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
	if w.Code != 409 {
		t.Fatalf("want 409, got %d %s", w.Code, w.Body)
	}
}

func TestPendingSecretEnds(t *testing.T) {
	e := usersEnv(t)
	cookies, csrf := e.loginAs("vi")
	h := map[string]string{"X-CSRF-Token": csrf}
	w := e.do(req{method: "POST", path: "/api/me/totp/setup", body: `{"password":"correct horse"}`, cookies: cookies, headers: h})
	var s struct{ Secret string }
	_ = json.Unmarshal(w.Body.Bytes(), &s)
	e.now = e.now.Add(pendingTTL + time.Second)
	// The session itself ends after its own time; sign in again.
	cookies, csrf = e.loginAs("vi")
	code, _ := totp.GenerateCode(s.Secret, e.now)
	w = e.do(req{method: "POST", path: "/api/me/totp/enable", body: `{"code":"` + code + `"}`, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
	if w.Code != 409 {
		t.Fatalf("a secret that waited too long must be refused, got %d %s", w.Code, w.Body)
	}
}

func TestTurningTheSecondFactorOffNeedsThePasswordAndACode(t *testing.T) {
	e, plain := twoFactorEnv(t)
	cookies, csrf := e.signIn(t)
	post := func(path, body string) *httptest.ResponseRecorder {
		return e.do(req{method: "POST", path: path, body: body, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
	}
	if w := post("/api/me/totp/disable", `{"password":"wrong one","code":"`+e.code()+`"}`); w.Code != 403 {
		t.Fatalf("a wrong password must be 403, got %d", w.Code)
	}
	if w := post("/api/me/totp/disable", `{"password":"correct horse","code":"000000"}`); w.Code != 403 {
		t.Fatalf("a wrong code must be 403, got %d", w.Code)
	}
	if strings.Contains(e.calls(), "totp-reset") {
		t.Fatal("nothing may change before both are right")
	}
	// The code of this period was spent by the sign-in, so the next one.
	e.now = e.now.Add(auth.TOTPPeriod * time.Second)
	if w := post("/api/me/totp/disable", `{"password":"correct horse","code":"`+plain[0]+`"}`); w.Code != 200 {
		t.Fatalf("a recovery code must be accepted here: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ARGS users totp-reset an") {
		t.Fatalf("dpistack must be told:\n%s", e.calls())
	}
}

func TestNewRecoveryCodesNeedACodeOfTheApp(t *testing.T) {
	e, plain := twoFactorEnv(t)
	cookies, csrf := e.signIn(t)
	post := func(body string) *httptest.ResponseRecorder {
		return e.do(req{method: "POST", path: "/api/me/totp/recovery", body: body, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}})
	}
	if w := post(`{"password":"correct horse","code":"` + plain[0] + `"}`); w.Code != 403 {
		t.Fatalf("a recovery code must not make recovery codes, got %d", w.Code)
	}
	e.now = e.now.Add(auth.TOTPPeriod * time.Second)
	w := post(`{"password":"correct horse","code":"` + e.code() + `"}`)
	if w.Code != 200 {
		t.Fatalf("recovery: %d %s", w.Code, w.Body)
	}
	var out struct{ Recovery []string }
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	if len(out.Recovery) != auth.RecoveryCount {
		t.Fatalf("want %d new codes, got %d", auth.RecoveryCount, len(out.Recovery))
	}
	log := e.calls()
	if !strings.Contains(log, "ARGS users totp-set an") || !strings.Contains(log, `"secret":"`+testTOTPSecret+`"`) {
		t.Fatalf("the secret stays, the codes change:\n%s", log)
	}
}

func TestAManagerTakesTheSecondFactorOffAndTheSessionsEnd(t *testing.T) {
	e, _ := twoFactorEnv(t)
	anCookies, _ := e.signIn(t)
	if w := e.as("vi", "POST", "/api/users/an/totp/reset", ""); !isForbidden(w) {
		t.Fatalf("a viewer must not reset it: %d %s", w.Code, w.Body)
	}
	w := e.as("admin", "POST", "/api/users/an/totp/reset", "")
	if w.Code != 200 {
		t.Fatalf("reset: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ARGS users totp-reset an") {
		t.Fatalf("dpistack must be told:\n%s", e.calls())
	}
	if w := e.do(req{method: "GET", path: "/api/me", cookies: anCookies}); w.Code != 401 {
		t.Fatalf("the sessions of the account must end, got %d", w.Code)
	}
	if w := e.as("admin", "POST", "/api/users/Bad_Name/totp/reset", ""); w.Code != 400 && w.Code != 404 {
		t.Fatalf("a bad name must be refused, got %d", w.Code)
	}
}
