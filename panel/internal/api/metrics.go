package api

import "net/http"

// metricsSeries handles GET /api/metrics?range=1h|6h|24h. No other period
// is served: the ring holds a day and the screen asks for three views of it.
func (s *server) metricsSeries(w http.ResponseWriter, r *http.Request) {
	if s.cfg.Metrics == nil {
		writeError(w, http.StatusServiceUnavailable, "metrics are not collected")
		return
	}
	rng := r.URL.Query().Get("range")
	if rng == "" {
		rng = "1h"
	}
	res, err := s.cfg.Metrics.Query(rng)
	if err != nil {
		writeError(w, http.StatusBadRequest, "range: 1h, 6h or 24h")
		return
	}
	writeJSON(w, http.StatusOK, res)
}
