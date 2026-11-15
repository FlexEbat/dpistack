package api

import "net/http"

// metricsSeries handles GET /api/metrics?range=Nh for a whole N from 1 to 24
// (the screen offers 1h, 6h, 12h, 24h and a number of hours of its own). No
// longer period is served: the ring holds a day.
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
		writeError(w, http.StatusBadRequest, "range: a whole number of hours from 1 to 24, for example 12h")
		return
	}
	writeJSON(w, http.StatusOK, res)
}
