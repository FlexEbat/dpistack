package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"net/http"
	"strings"
)

// metricsExport handles GET /metrics (tech.md 4.9): Prometheus text, for a
// scraper that sends the token as "Authorization: Bearer <token>". No
// session is involved; the address policy of 4.8 still applies, because it
// guards every request. Without a token configured the page does not exist.
func (s *server) metricsExport(w http.ResponseWriter, r *http.Request) {
	if s.cfg.Export == nil || s.cfg.ExportToken == "" {
		writeError(w, http.StatusNotFound, "не найдено")
		return
	}
	// The scheme must be there: a bare token is not accepted. The word
	// "Bearer" is case-insensitive (RFC 7235).
	header := r.Header.Get("Authorization")
	got, hasScheme := "", len(header) > 7 && strings.EqualFold(header[:7], "Bearer ")
	if hasScheme {
		got = strings.TrimSpace(header[7:])
	}
	// Hashes first, so the comparison takes the same time whatever the length.
	a, b := sha256.Sum256([]byte(got)), sha256.Sum256([]byte(s.cfg.ExportToken))
	if !hasScheme || got == "" || subtle.ConstantTimeCompare(a[:], b[:]) != 1 {
		w.Header().Set("WWW-Authenticate", `Bearer realm="dpistack"`)
		writeError(w, http.StatusUnauthorized, "нужен токен")
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(s.cfg.Export.Render())
}
