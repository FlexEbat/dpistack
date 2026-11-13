package api

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/audit"
	"github.com/FlexEbat/dpistack/panel/internal/auth"
)

// The security page (tech.md 18.45): API tokens, the sessions of the user,
// the history of sign ins, and the security check.

var (
	tokenName    = regexp.MustCompile(`^[a-z0-9][a-z0-9 ._-]{0,31}$`)
	tokenID      = regexp.MustCompile(`^[0-9a-f]{8}$`)
	sessionID    = regexp.MustCompile(`^[0-9a-f]{16}$`)
	tokenScopes  = map[string]bool{"read": true, "viewer": true, "analyst": true, "operator": true, "admin": true}
	loginsMax    = 200
	loginsNormal = 50
)

// bearer authenticates a request that came with `Authorization: Bearer`. A
// token is not a session: it needs no CSRF token (nothing in a browser sends
// it by itself), it acts as its owner with at most the permissions of its
// scope, and a read token may only read. A wrong token is counted per address;
// a right one is not, so a script is never locked out by its own traffic.
func (s *server) bearer(next http.HandlerFunc, w http.ResponseWriter, r *http.Request, header string) {
	// The word "Bearer" is case-insensitive (RFC 7235), as in the metrics export.
	secret, ok := "", len(header) > 7 && strings.EqualFold(header[:7], "Bearer ")
	if ok {
		secret = strings.TrimSpace(header[7:])
	}
	if !ok || secret == "" {
		writeError(w, http.StatusUnauthorized, "sign-in required")
		return
	}
	o, _ := r.Context().Value(ctxKey{}).(origin)
	if blocked, wait := s.tokenLimiter.Blocked(o.client); blocked {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		writeError(w, http.StatusTooManyRequests, "too many wrong tokens, try again later")
		return
	}
	tk, found, err := s.tokens.Lookup(secret)
	if err != nil {
		log.Printf("api token: %v", err)
	}
	if err != nil || !found {
		s.tokenLimiter.Attempt(o.client)
		writeError(w, http.StatusUnauthorized, "sign-in required")
		return
	}
	// The owner is read on every request, as for a session: a token whose
	// owner was disabled or removed stops at once.
	owner, found, err := s.users.Find(tk.User)
	if err != nil || !found {
		writeError(w, http.StatusUnauthorized, "sign-in required")
		return
	}
	if act := actorOf(r); act != nil {
		act.user = "token:" + tk.Name
	}
	if tk.Scope == auth.ScopeRead && r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodOptions {
		writeError(w, http.StatusForbidden, "this token is read only")
		return
	}
	s.lastUsed.Store(tk.ID, s.cfg.Now())
	ctx := context.WithValue(r.Context(), principalKey{}, principal{user: auth.TokenUser(tk, owner), token: tk.ID})
	next(w, r.WithContext(ctx))
}

// sessionOnly refuses a request that came with an API token: tokens and
// sessions are managed from the panel, never with a token, so a leaked token
// cannot make another one or end the sessions of its owner.
func sessionOnly(w http.ResponseWriter, r *http.Request) bool {
	p, _ := r.Context().Value(principalKey{}).(principal)
	if p.token != "" {
		writeError(w, http.StatusForbidden, "this needs a signed-in session, not an API token")
		return false
	}
	return true
}

// currentSession is the id of the session cookie of this request.
func currentSession(r *http.Request) string {
	if c, err := r.Cookie(sessionCookie); err == nil {
		return c.Value
	}
	return ""
}

func wantsAll(r *http.Request) bool { return r.URL.Query().Get("all") == "1" }

// ---- sessions ----

type sessionView struct {
	auth.SessionInfo
	Current bool `json:"current"`
}

// securitySessions handles GET /api/security/sessions[?all=1].
func (s *server) securitySessions(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	me := who(r)
	user := me.Name
	if wantsAll(r) {
		if !me.Has(auth.PermUsersManage) {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "forbidden", "permission": auth.PermUsersManage})
			return
		}
		user = ""
	}
	mine := auth.Handle(currentSession(r))
	out := []sessionView{}
	for _, v := range s.sessions.List(user) {
		out = append(out, sessionView{SessionInfo: v, Current: v.Handle == mine})
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
}

// securitySessionEnd handles DELETE /api/security/sessions/{handle}: one's own.
func (s *server) securitySessionEnd(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	h := r.PathValue("handle")
	if !sessionID.MatchString(h) {
		writeError(w, http.StatusBadRequest, "a session handle is 16 hex digits")
		return
	}
	auditDetail(r, "end session "+h)
	if !s.sessions.RevokeHandle(who(r).Name, h) {
		writeError(w, http.StatusNotFound, "no such session")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// securitySessionsOthers handles POST /api/security/sessions/revoke-others.
func (s *server) securitySessionsOthers(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	n := s.sessions.RevokeOthers(who(r).Name, currentSession(r))
	auditDetail(r, "ended "+strconv.Itoa(n)+" other sessions")
	writeJSON(w, http.StatusOK, map[string]any{"ended": n})
}

// securitySessionsAll handles POST /api/security/sessions/revoke-all: every
// session of everyone, this one too. There is no key to rotate (a session is
// a random token that lives in the memory of the panel), so this is the way
// to make every cookie that was ever given out worthless.
func (s *server) securitySessionsAll(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	n := s.sessions.RevokeAll()
	auditDetail(r, "ended all "+strconv.Itoa(n)+" sessions")
	for _, name := range []string{sessionCookie, csrfCookie} {
		http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1, SameSite: http.SameSiteStrictMode})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ended": n})
}

// ---- tokens ----

type tokenView struct {
	ID       string     `json:"id"`
	Name     string     `json:"name"`
	User     string     `json:"user"`
	Scope    string     `json:"scope"`
	Created  string     `json:"created"`
	Expires  string     `json:"expires"`
	Expired  bool       `json:"expired"`
	LastUsed *time.Time `json:"last_used,omitempty"`
}

// securityTokens handles GET /api/security/tokens[?all=1].
func (s *server) securityTokens(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	me := who(r)
	if wantsAll(r) && !me.Has(auth.PermUsersManage) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "forbidden", "permission": auth.PermUsersManage})
		return
	}
	list, err := s.tokens.List()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "the tokens file cannot be read")
		return
	}
	now := s.cfg.Now()
	out := []tokenView{}
	for _, tk := range list {
		if !wantsAll(r) && tk.User != me.Name {
			continue
		}
		v := tokenView{ID: tk.ID, Name: tk.Name, User: tk.User, Scope: tk.Scope, Created: tk.Created, Expires: tk.Expires, Expired: tk.Expired(now)}
		if t, ok := s.lastUsed.Load(tk.ID); ok {
			tt := t.(time.Time)
			v.LastUsed = &tt
		}
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created > out[j].Created })
	writeJSON(w, http.StatusOK, map[string]any{"tokens": out})
}

// securityTokenCreate handles POST /api/security/tokens with {name, scope,
// days}. The answer holds the secret, and nothing else ever does.
func (s *server) securityTokenCreate(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	var body struct {
		Name  string `json:"name"`
		Scope string `json:"scope"`
		Days  int    `json:"days"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, `the body is {"name":"ci","scope":"read","days":90}`)
		return
	}
	if !tokenName.MatchString(body.Name) {
		writeError(w, http.StatusBadRequest, "the name is 1 to 32 characters: lowercase letters, digits, space and . _ -, starting with a letter or digit")
		return
	}
	if !tokenScopes[body.Scope] {
		writeError(w, http.StatusBadRequest, "the scope is read, viewer, analyst, operator or admin")
		return
	}
	if body.Days < 1 || body.Days > 365 {
		writeError(w, http.StatusBadRequest, "days is 1 to 365")
		return
	}
	auditDetail(r, "create "+body.Name+" "+body.Scope)
	out, err := s.cfg.Ctl.TokensCreate(r.Context(), who(r).Name, body.Name, body.Scope, body.Days)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// securityTokenRevoke handles DELETE /api/security/tokens/{id}: one's own, or
// any for a user who manages users. An unknown token and someone else's look
// the same.
func (s *server) securityTokenRevoke(w http.ResponseWriter, r *http.Request) {
	if !sessionOnly(w, r) {
		return
	}
	id := r.PathValue("id")
	if !tokenID.MatchString(id) {
		writeError(w, http.StatusBadRequest, "a token id is 8 hex digits")
		return
	}
	list, err := s.tokens.List()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "the tokens file cannot be read")
		return
	}
	me := who(r)
	owner := ""
	for _, tk := range list {
		if tk.ID == id && (tk.User == me.Name || me.Has(auth.PermUsersManage)) {
			owner = tk.User
		}
	}
	if owner == "" {
		writeError(w, http.StatusNotFound, "no such token")
		return
	}
	auditDetail(r, "revoke "+id)
	if err := s.cfg.Ctl.TokensRevoke(r.Context(), id, owner); err != nil {
		opError(w, err)
		return
	}
	s.lastUsed.Delete(id)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ---- sign in history and the check ----

type loginView struct {
	TS     string `json:"ts"`
	User   string `json:"user"`
	IP     string `json:"ip"`
	Result string `json:"result"`
}

// securityLogins handles GET /api/security/logins[?user=NAME|all=1][&limit=N].
// One's own history is for anyone; another user's or everyone's needs
// audit.view. It is read from the audit log, which already has a line for
// every sign in, right or wrong.
func (s *server) securityLogins(w http.ResponseWriter, r *http.Request) {
	me := who(r)
	q := r.URL.Query()
	user := me.Name
	if wantsAll(r) {
		user = ""
	} else if u := q.Get("user"); u != "" {
		user = u
	}
	if user != me.Name && !me.Has(auth.PermAuditView) {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": "forbidden", "permission": auth.PermAuditView})
		return
	}
	limit := loginsNormal
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > loginsMax {
			writeError(w, http.StatusBadRequest, "limit is a number from 1 to "+strconv.Itoa(loginsMax))
			return
		}
		limit = n
	}
	out := []loginView{}
	if s.cfg.Audit != nil {
		// The filter matches a part of the action, so the entries are checked
		// again for the exact route.
		entries, err := s.cfg.Audit.Read(audit.Filter{User: user, Action: "POST /api/login", Limit: audit.MaxRead})
		if err != nil {
			writeError(w, http.StatusInternalServerError, "the audit log cannot be read")
			return
		}
		for _, e := range entries {
			if e.Action != "POST /api/login" {
				continue
			}
			out = append(out, loginView{TS: e.TS, User: e.User, IP: e.IP, Result: e.Result})
			if len(out) == limit {
				break
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"logins": out})
}

// securityCheck handles GET /api/security/check.
func (s *server) securityCheck(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.SecurityCheck(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}
