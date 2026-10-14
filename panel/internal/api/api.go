// Package api is the panel's HTTP server (tech.md 4.8): address policy,
// login, sessions, CSRF and the JSON endpoints.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
	"github.com/FlexEbat/dpistack/panel/internal/health"
)

const (
	sessionCookie = "dpistack_session"
	// csrfCookie is readable by the page script, which echoes it in the
	// X-CSRF-Token header. The server compares the header with the token
	// stored for the session, so a forged cookie proves nothing.
	csrfCookie  = "dpistack_csrf"
	sessionTTL  = 12 * time.Hour
	loginMax    = 5
	loginWindow = 5 * time.Minute
	maxBody     = 4096
)

// Config is everything the server needs from the outside.
type Config struct {
	Policy     *auth.Policy
	AuthFile   string
	HealthFile string
	Ctl        *ctl.Runner
	Web        fs.FS
	Now        func() time.Time // nil means time.Now
}

type server struct {
	cfg      Config
	sessions *auth.Sessions
	limiter  *auth.Limiter
	streams  atomic.Int32 // open log streams, capped at maxStreams
}

type ctxKey struct{}

type origin struct{ peer, client netip.Addr }

// New returns the panel handler.
func New(cfg Config) http.Handler {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	s := &server{
		cfg:      cfg,
		sessions: auth.NewSessions(sessionTTL, cfg.Now),
		limiter:  auth.NewLimiter(loginMax, loginWindow, cfg.Now),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/login", s.login)
	mux.HandleFunc("POST /api/logout", s.authed(s.logout))
	mux.HandleFunc("GET /api/status", s.authed(s.status))
	mux.HandleFunc("POST /api/components/{id}/{action}", s.authed(s.control))
	mux.HandleFunc("POST /api/suricata/reload", s.authed(s.reloadSuricata))
	mux.HandleFunc("GET /api/config", s.authed(s.configList))
	mux.HandleFunc("GET /api/config/{name}", s.authed(s.configGet))
	mux.HandleFunc("PUT /api/config/{name}", s.authed(s.configPut))
	mux.HandleFunc("POST /api/config/{name}/check", s.authed(s.configCheck))
	mux.HandleFunc("POST /api/config/{name}/revert", s.authed(s.configRevert))
	mux.HandleFunc("GET /api/logs/{id}", s.authed(s.logs))
	mux.HandleFunc("GET /api/logs/{id}/stream", s.authed(s.logStream))
	// Every other /api path answers 401 without a session, so the API
	// does not reveal which paths exist.
	mux.HandleFunc("/api/", s.authed(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, http.StatusNotFound, "нет такого метода")
	}))
	if cfg.Web != nil {
		mux.Handle("/", static(http.FileServerFS(cfg.Web)))
	}
	return s.guard(mux)
}

// static serves the embedded site for GET and HEAD only. It is registered
// for every method because "GET /" conflicts with the "/api/" catch-all.
func static(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeError(w, http.StatusMethodNotAllowed, "метод не поддерживается")
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		next.ServeHTTP(w, r)
	})
}

// guard applies the address policy to every request, static files included.
func (s *server) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		if strings.HasPrefix(r.URL.Path, "/api/") {
			h.Set("Cache-Control", "no-store")
		}

		peer, client, err := s.cfg.Policy.ClientIP(r.RemoteAddr, r.Header.Values("X-Forwarded-For"))
		if err != nil || !s.cfg.Policy.Allowed(peer, client) {
			writeError(w, http.StatusForbidden, "доступ с этого адреса запрещён")
			return
		}
		ctx := context.WithValue(r.Context(), ctxKey{}, origin{peer: peer, client: client})
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// authed requires a live session and, for methods that change state, the
// session's CSRF token in X-CSRF-Token.
func (s *server) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var csrf string
		ok := false
		if c, err := r.Cookie(sessionCookie); err == nil {
			csrf, ok = s.sessions.Get(c.Value)
		}
		if !ok {
			writeError(w, http.StatusUnauthorized, "требуется вход")
			return
		}
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
		default:
			if subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CSRF-Token")), []byte(csrf)) != 1 {
				writeError(w, http.StatusForbidden, "неверный CSRF-токен")
				return
			}
		}
		next(w, r)
	}
}

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	o := r.Context().Value(ctxKey{}).(origin)

	// The attempt is counted before anything is read or checked.
	if ok, wait := s.limiter.Attempt(o.client); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(int(wait.Seconds())+1))
		log.Printf("login: too many attempts from %s", o.client)
		writeError(w, http.StatusTooManyRequests, "слишком много попыток входа, повторите позже")
		return
	}

	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "нужен Content-Type: application/json")
		return
	}
	var body struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "неверный запрос")
		return
	}

	good, err := auth.VerifyFile(s.cfg.AuthFile, body.Password)
	switch {
	case errors.Is(err, auth.ErrNoPassword):
		writeError(w, http.StatusInternalServerError, "пароль панели не задан: задайте его пунктом «Пароль панели» команды dpistack")
		return
	case errors.Is(err, auth.ErrHashTooHeavy):
		writeError(w, http.StatusInternalServerError, "хэш пароля требует больше памяти, чем доступно панели: задайте пароль заново пунктом «Пароль панели» команды dpistack")
		return
	case err != nil:
		log.Printf("login: %v", err)
		writeError(w, http.StatusInternalServerError, "не удалось проверить пароль: файл пароля повреждён или недоступен")
		return
	case !good:
		log.Printf("login: wrong password from %s", o.client)
		writeError(w, http.StatusUnauthorized, "неверный пароль")
		return
	}

	s.limiter.Reset(o.client)
	id, csrf := s.sessions.Create()
	secure := r.TLS != nil || (o.peer.IsLoopback() && r.Header.Get("X-Forwarded-Proto") == "https")
	setCookie(w, sessionCookie, id, true, secure)
	setCookie(w, csrfCookie, csrf, false, secure)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *server) logout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookie); err == nil {
		s.sessions.Delete(c.Value)
	}
	for _, name := range []string{sessionCookie, csrfCookie} {
		http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1, SameSite: http.SameSiteStrictMode})
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func setCookie(w http.ResponseWriter, name, value string, httpOnly, secure bool) {
	http.SetCookie(w, &http.Cookie{
		Name:     name,
		Value:    value,
		Path:     "/",
		MaxAge:   int(sessionTTL.Seconds()),
		HttpOnly: httpOnly,
		Secure:   secure,
		SameSite: http.SameSiteStrictMode,
	})
}

type statusResponse struct {
	Components []ctl.Component `json:"components"`
	NDPIPlugin string          `json:"ndpi_plugin"`
	Health     *health.Report  `json:"health"`
}

// status merges `ctl status` with health.json. Health is null until the
// watchdog has written its first report.
func (s *server) status(w http.ResponseWriter, r *http.Request) {
	st, err := s.cfg.Ctl.Status(r.Context())
	if err != nil {
		detail := strings.TrimPrefix(err.Error(), ctl.ErrUnavailable.Error()+": ")
		writeError(w, http.StatusBadGateway, "dpistack-ctl недоступен: "+detail)
		return
	}
	rep, err := health.Read(s.cfg.HealthFile)
	if err != nil {
		writeError(w, http.StatusBadGateway, "не удалось прочитать health.json: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, statusResponse{Components: st.Components, NDPIPlugin: st.NDPIPlugin, Health: rep})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}

func writeError(w http.ResponseWriter, code int, text string) {
	writeJSON(w, code, map[string]string{"error": text})
}
