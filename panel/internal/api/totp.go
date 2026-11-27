package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image/png"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/pquerna/otp"
	"github.com/pquerna/otp/totp"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
)

// Two factor sign-in (task 65): an account may have a TOTP secret and
// recovery codes in users.json. The panel reads them; it changes them only
// through `dpistack users totp-*`, like every other change of an account.

const (
	// pendingTTL is how long a secret that was shown waits for its first code.
	pendingTTL = 10 * time.Minute
	totpIssuer = "dpistack"
	// totpLoginMax is how many second-factor attempts one address gets in a
	// loginWindow. It is its own counter: a right password does not clear it,
	// so a stolen password does not give unlimited tries at the code.
	totpLoginMax = 10
)

// totpState is what the panel keeps in memory for the second factor.
type totpState struct {
	guard   *auth.TOTPGuard
	tickets *auth.Tickets
	limiter *auth.Limiter

	mu      sync.Mutex
	pending map[string]pendingTOTP
}

type pendingTOTP struct {
	secret  string
	expires time.Time
}

func newTOTPState(now func() time.Time) *totpState {
	return &totpState{
		guard:   &auth.TOTPGuard{Now: now},
		tickets: &auth.Tickets{Now: now},
		limiter: auth.NewLimiter(totpLoginMax, loginWindow, now),
		pending: map[string]pendingTOTP{},
	}
}

func (t *totpState) setPending(user, secret string, expires time.Time) {
	t.mu.Lock()
	t.pending[user] = pendingTOTP{secret: secret, expires: expires}
	t.mu.Unlock()
}

func (t *totpState) takePending(user string, now time.Time) (string, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	p, ok := t.pending[user]
	if !ok || now.After(p.expires) {
		delete(t.pending, user)
		return "", false
	}
	return p.secret, true
}

func (t *totpState) dropPending(user string) {
	t.mu.Lock()
	delete(t.pending, user)
	t.mu.Unlock()
}

func hasTOTP(u auth.User) bool {
	return u.TOTP != nil && u.TOTP.Secret != ""
}

// loginTOTP handles POST /api/login/totp: the second step of a sign-in whose
// password was right. A ticket from the first step and either the code of the
// authenticator app or a recovery code.
func (s *server) loginTOTP(w http.ResponseWriter, r *http.Request) {
	o := r.Context().Value(ctxKey{}).(origin)
	if ok, wait := s.totp.limiter.Attempt(o.client); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		log.Printf("login: too many second-factor attempts from %s", o.client)
		writeError(w, http.StatusTooManyRequests, "too many sign-in attempts, try again later")
		return
	}
	var body struct {
		Ticket   string `json:"ticket"`
		Code     string `json:"code"`
		Recovery string `json:"recovery"`
	}
	if !decodeJSON(w, r, &body) {
		return
	}
	name, ok := s.totp.tickets.Peek(body.Ticket, o.client.String())
	if !ok {
		writeError(w, http.StatusUnauthorized, "the sign-in took too long or did not start here: enter the password again")
		return
	}
	auditUser(r, name)
	u, found, err := s.users.Find(name)
	if err != nil {
		log.Printf("login: %v", err)
		writeError(w, http.StatusInternalServerError, "could not check the code: the password file is damaged or unreadable")
		return
	}
	if !found || !hasTOTP(u) {
		s.totp.tickets.Done(body.Ticket)
		writeError(w, http.StatusUnauthorized, "the sign-in took too long or did not start here: enter the password again")
		return
	}

	left := len(u.TOTP.Recovery)
	good := false
	switch {
	case body.Recovery != "":
		if hash, match := u.TOTP.MatchRecovery(body.Recovery); match {
			// Used up before the session exists: a failure here is a failed
			// sign-in, never a code that stays good.
			if _, err := s.cfg.Ctl.UsersTOTPUsed(r.Context(), name, hash); err != nil {
				ctlError(w, err)
				return
			}
			good = true
			left--
			auditDetail(r, "recovery code used, "+strconv.Itoa(left)+" left")
		}
	case body.Code != "":
		good = s.totp.guard.Check(name, u.TOTP.Secret, body.Code)
	}
	if !good {
		s.totp.tickets.Fail(body.Ticket)
		log.Printf("login: wrong second factor for %s from %s", name, o.client)
		writeError(w, http.StatusUnauthorized, "wrong code")
		return
	}

	s.totp.tickets.Done(body.Ticket)
	s.totp.limiter.Reset(o.client)
	id, csrf := s.sessions.CreateMeta(u.Name, o.client.String(), r.UserAgent())
	secure := r.TLS != nil || (o.peer.IsLoopback() && r.Header.Get("X-Forwarded-Proto") == "https")
	setCookie(w, sessionCookie, id, true, secure)
	setCookie(w, csrfCookie, csrf, false, secure)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "recovery_left": left})
}

// checkSecondFactor is for the changes of an account that need the password
// and a code: a code of the app, or when allowRecovery a recovery code too.
func (s *server) checkSecondFactor(r *http.Request, u auth.User, code string, allowRecovery bool) (ok bool, recoveryHash string) {
	if s.totp.guard.Check(u.Name, u.TOTP.Secret, code) {
		return true, ""
	}
	if allowRecovery {
		if h, match := u.TOTP.MatchRecovery(code); match {
			return true, h
		}
	}
	return false, ""
}

// totpSetup handles POST /api/me/totp/setup: a new secret for the account,
// with the current password. Nothing is stored until the first code proves
// that the app has it.
func (s *server) totpSetup(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Password string `json:"password"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	me := who(r)
	if hasTOTP(me) {
		writeError(w, http.StatusConflict, "two factor sign in is already on: turn it off first")
		return
	}
	if _, good, err := s.users.Login(me.Name, b.Password); err != nil || !good {
		writeError(w, http.StatusForbidden, "the password is wrong")
		return
	}
	key, err := totp.Generate(totp.GenerateOpts{
		Issuer:      totpIssuer,
		AccountName: me.Name,
		Period:      auth.TOTPPeriod,
		Digits:      otp.DigitsSix,
		Algorithm:   otp.AlgorithmSHA1,
	})
	if err != nil {
		log.Printf("totp: %v", err)
		writeError(w, http.StatusInternalServerError, "could not make a secret")
		return
	}
	s.totp.setPending(me.Name, key.Secret(), s.cfg.Now().Add(pendingTTL))
	auditDetail(r, "two factor setup started")
	writeJSON(w, http.StatusOK, map[string]string{
		"secret": key.Secret(),
		"uri":    key.URL(),
		"qr":     qrDataURL(key),
	})
}

func qrDataURL(key *otp.Key) string {
	img, err := key.Image(220, 220)
	if err != nil {
		return ""
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(buf.Bytes())
}

// totpEnable handles POST /api/me/totp/enable: the first code of the app turns
// the second factor on and returns the recovery codes, once.
func (s *server) totpEnable(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Code string `json:"code"`
	}
	if !decodeJSON(w, r, &b) {
		return
	}
	me := who(r)
	if hasTOTP(me) {
		writeError(w, http.StatusConflict, "two factor sign in is already on")
		return
	}
	secret, ok := s.totp.takePending(me.Name, s.cfg.Now())
	if !ok {
		writeError(w, http.StatusConflict, "start again: the secret was not asked for or it is too old")
		return
	}
	if !s.totp.guard.Valid(secret, b.Code) {
		writeError(w, http.StatusUnprocessableEntity, "that code is not right: check the clock of the phone and try the next code")
		return
	}
	plain, hashes, err := auth.NewRecoveryCodes()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not make recovery codes")
		return
	}
	if _, err := s.cfg.Ctl.UsersTOTPSet(r.Context(), me.Name, secret, hashes); err != nil {
		ctlError(w, err)
		return
	}
	s.totp.dropPending(me.Name)
	s.keepOnlyThisSession(r, me.Name)
	auditDetail(r, "two factor sign in on")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "recovery": plain})
}

// totpRecovery handles POST /api/me/totp/recovery: a new set of recovery
// codes (the old ones stop working), with the password and a code of the app.
func (s *server) totpRecovery(w http.ResponseWriter, r *http.Request) {
	u, ok := s.totpGuarded(w, r, false)
	if !ok {
		return
	}
	plain, hashes, err := auth.NewRecoveryCodes()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not make recovery codes")
		return
	}
	if _, err := s.cfg.Ctl.UsersTOTPSet(r.Context(), u.Name, u.TOTP.Secret, hashes); err != nil {
		ctlError(w, err)
		return
	}
	auditDetail(r, "recovery codes made again")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "recovery": plain})
}

// totpDisable handles POST /api/me/totp/disable: with the password and a
// code of the app or a recovery code.
func (s *server) totpDisable(w http.ResponseWriter, r *http.Request) {
	u, ok := s.totpGuarded(w, r, true)
	if !ok {
		return
	}
	if _, err := s.cfg.Ctl.UsersTOTPReset(r.Context(), u.Name); err != nil {
		ctlError(w, err)
		return
	}
	s.totp.guard.Forget(u.Name)
	s.keepOnlyThisSession(r, u.Name)
	auditDetail(r, "two factor sign in off")
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// totpGuarded reads {password, code} of the signed-in user and checks both.
// It answers the error itself and returns false.
func (s *server) totpGuarded(w http.ResponseWriter, r *http.Request, allowRecovery bool) (auth.User, bool) {
	var b struct {
		Password string `json:"password"`
		Code     string `json:"code"`
	}
	if !decodeJSON(w, r, &b) {
		return auth.User{}, false
	}
	me := who(r)
	if !hasTOTP(me) {
		writeError(w, http.StatusConflict, "two factor sign in is not on")
		return auth.User{}, false
	}
	// The same counter as the sign-in: a stolen session cannot guess the
	// code here without limit.
	o := r.Context().Value(ctxKey{}).(origin)
	if allowed, wait := s.totp.limiter.Attempt(o.client); !allowed {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		writeError(w, http.StatusTooManyRequests, "too many attempts, try again later")
		return auth.User{}, false
	}
	if _, good, err := s.users.Login(me.Name, b.Password); err != nil || !good {
		writeError(w, http.StatusForbidden, "the password is wrong")
		return auth.User{}, false
	}
	good, hash := s.checkSecondFactor(r, me, b.Code, allowRecovery)
	if !good {
		writeError(w, http.StatusForbidden, "wrong code")
		return auth.User{}, false
	}
	s.totp.limiter.Reset(o.client)
	if hash != "" {
		// The account is about to have no second factor, so spending the
		// code is only tidiness; a failure of it is not worth stopping for.
		if _, err := s.cfg.Ctl.UsersTOTPUsed(r.Context(), me.Name, hash); err != nil {
			log.Printf("totp: recovery code not marked used: %v", err)
		}
	}
	return me, true
}

// usersTOTPReset handles POST /api/users/{name}/totp/reset: a manager takes
// the second factor off an account whose device is lost. The sessions of that
// account end.
func (s *server) usersTOTPReset(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !userName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "bad user name")
		return
	}
	auditDetail(r, "user="+name+" two factor reset")
	if _, err := s.cfg.Ctl.UsersTOTPReset(r.Context(), name); err != nil {
		ctlError(w, err)
		return
	}
	s.totp.guard.Forget(name)
	s.totp.dropPending(name)
	s.sessions.DeleteUser(name)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// keepOnlyThisSession ends the other sessions of an account when its second
// factor changes: a session that was made without the new factor must not
// outlive the change.
func (s *server) keepOnlyThisSession(r *http.Request, name string) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		s.sessions.RevokeOthers(name, c.Value)
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return false
	}
	return true
}
