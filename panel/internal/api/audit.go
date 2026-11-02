package api

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/audit"
)

// actor is filled while a request runs: authed puts the user in, a handler
// may add a detail (names and flags only, never a value that is a secret).
type actor struct {
	user   string
	detail string
}

type actorKey struct{}

func actorOf(r *http.Request) *actor {
	a, _ := r.Context().Value(actorKey{}).(*actor)
	return a
}

// auditDetail adds a short note to the audit line of this request.
func auditDetail(r *http.Request, s string) {
	if a := actorOf(r); a != nil {
		a.detail = s
	}
}

// auditUser names the user of this request when authed did not (a login).
func auditUser(r *http.Request, name string) {
	if a := actorOf(r); a != nil && a.user == "" {
		a.user = name
	}
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func resultOf(status int) string {
	switch {
	case status == 0 || status < 400:
		return audit.ResultOK
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		return audit.ResultDenied
	default:
		return audit.ResultError
	}
}

// audited writes one line for every call that can change something: any
// method but GET, HEAD and OPTIONS under /api/, whoever it is and whatever it
// returns. The body of the request is never read here.
func (s *server) audited(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.Audit == nil || !strings.HasPrefix(r.URL.Path, "/api/") ||
			r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions {
			next.ServeHTTP(w, r)
			return
		}
		a := &actor{}
		r2 := r.WithContext(context.WithValue(r.Context(), actorKey{}, a))
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r2)
		user := a.user
		if user == "" {
			user = "-"
		}
		ip := ""
		if o, ok := r.Context().Value(ctxKey{}).(origin); ok {
			ip = o.client.String()
		}
		action := r2.Pattern
		if action == "" {
			action = r.Method + " " + r.URL.Path
		}
		_ = s.cfg.Audit.Write(audit.Entry{
			User: user, IP: ip, Action: action, Target: r.URL.Path,
			Result: resultOf(sw.status), Detail: a.detail,
		})
	})
}

func parseTime(v string) (time.Time, bool) {
	if v == "" {
		return time.Time{}, true
	}
	for _, layout := range []string{time.RFC3339, "2006-01-02T15:04", "2006-01-02"} {
		if t, err := time.Parse(layout, v); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

func auditFilter(r *http.Request) (audit.Filter, bool) {
	q := r.URL.Query()
	f := audit.Filter{User: q.Get("user"), Action: q.Get("action"), Result: q.Get("result")}
	switch f.Result {
	case "", audit.ResultOK, audit.ResultDenied, audit.ResultError:
	default:
		return f, false
	}
	var ok1, ok2 bool
	f.Since, ok1 = parseTime(q.Get("since"))
	f.Until, ok2 = parseTime(q.Get("until"))
	if !ok1 || !ok2 {
		return f, false
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			return f, false
		}
		f.Limit = n
	}
	return f, true
}

// auditList handles GET /api/audit.
func (s *server) auditList(w http.ResponseWriter, r *http.Request) {
	f, ok := auditFilter(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "bad filter: result is ok, denied or error; since and until are dates; limit is a number")
		return
	}
	list, err := s.cfg.Audit.Read(f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read the audit log")
		return
	}
	if list == nil {
		list = []audit.Entry{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": list, "enabled": s.cfg.Audit != nil && s.cfg.Audit.Path != ""})
}

// auditExport handles GET /api/audit/export?format=csv|json: the same filters,
// up to 5000 lines, as a download.
func (s *server) auditExport(w http.ResponseWriter, r *http.Request) {
	f, ok := auditFilter(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "bad filter")
		return
	}
	if f.Limit == 0 {
		f.Limit = audit.MaxRead
	}
	list, err := s.cfg.Audit.Read(f)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read the audit log")
		return
	}
	switch r.URL.Query().Get("format") {
	case "csv":
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.Header().Set("Content-Disposition", `attachment; filename="dpistack-audit.csv"`)
		_ = audit.WriteCSV(w, list)
	case "", "json":
		if list == nil {
			list = []audit.Entry{}
		}
		w.Header().Set("Content-Disposition", `attachment; filename="dpistack-audit.json"`)
		writeJSON(w, http.StatusOK, list)
	default:
		writeError(w, http.StatusBadRequest, "format is csv or json")
	}
}
