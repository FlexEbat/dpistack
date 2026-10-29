package api

import (
	"net/http"

	"github.com/FlexEbat/dpistack/panel/internal/update"
)

// versionInfo is what the corner of every screen shows. Without a checker
// (the check is switched off) only the running version is known.
func (s *server) versionInfo(r *http.Request) update.Info {
	if s.cfg.Update == nil {
		return update.Info{Current: s.cfg.Version}
	}
	return s.cfg.Update.Get(r.Context())
}

// versionGet handles GET /api/version.
func (s *server) versionGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.versionInfo(r))
}

// updateStart handles POST /api/update. The person confirmed in the dialog;
// the server still checks that a newer release exists, and root re-checks it
// again (`dpistack self-update run`), so a forged request cannot install an
// older or an unknown version.
func (s *server) updateStart(w http.ResponseWriter, r *http.Request) {
	if s.cfg.Update == nil {
		writeError(w, http.StatusConflict, "the update check is switched off")
		return
	}
	s.cfg.Update.Refresh()
	info := s.cfg.Update.Get(r.Context())
	if !info.Available {
		writeError(w, http.StatusConflict, "there is no newer release")
		return
	}
	out, err := s.cfg.Ctl.SelfUpdateStart(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true, "latest": info.Latest, "output": out})
}

// updateJob handles GET /api/update/job: the state of the update unit.
func (s *server) updateJob(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.SelfUpdateJob(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(out)
}
