package api

import (
	"net/http"
)

// systemGet handles GET /api/system: the state of the host and its
// interfaces. The capture flag of an interface comes from `ctl iface list`
// (the IFACES of the config); when that fails the flag is left out rather
// than guessed.
func (s *server) systemGet(w http.ResponseWriter, r *http.Request) {
	if s.cfg.System == nil {
		writeError(w, http.StatusNotFound, "the system page is switched off")
		return
	}
	info := s.cfg.System.Read()
	if s.cfg.Ctl != nil {
		if names, err := s.cfg.Ctl.IfaceList(r.Context()); err == nil {
			capturing := map[string]bool{}
			for _, n := range names {
				capturing[n] = true
			}
			for i := range info.Interfaces {
				v := capturing[info.Interfaces[i].Name]
				info.Interfaces[i].Capture = &v
			}
		}
	}
	writeJSON(w, http.StatusOK, info)
}
