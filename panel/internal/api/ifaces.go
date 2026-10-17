package api

import (
	"context"
	"encoding/json"
	"net/http"
	"regexp"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// ifaceName is what ctl accepts: the length of a Linux interface name and
// its usual characters.
var ifaceName = regexp.MustCompile(`^[A-Za-z0-9._-]{1,15}$`)

// ifaceList handles GET /api/iface: the interfaces Suricata listens on, from
// `ctl iface list`.
func (s *server) ifaceList(w http.ResponseWriter, r *http.Request) {
	names, err := s.cfg.Ctl.IfaceList(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ifaces": names})
}

// ifaceChange handles POST /api/iface/{add|remove} with {"name":"..."}.
// ctl writes IFACES and runs reconfigure, and puts the file back if that
// fails; it runs detached from the request so that a closed browser cannot
// interrupt it halfway. One change at a time.
func (s *server) ifaceChange(w http.ResponseWriter, r *http.Request) {
	verb := r.PathValue("action")
	if verb != "add" && verb != "remove" {
		writeError(w, http.StatusNotFound, "нет такого действия")
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "неверный запрос")
		return
	}
	if !ifaceName.MatchString(body.Name) {
		writeError(w, http.StatusBadRequest, "имя интерфейса: до 15 знаков, буквы, цифры, точка, дефис и подчёркивание")
		return
	}
	if !s.ops.begin(&s.ops.ifaceBusy) {
		writeError(w, http.StatusConflict, "список интерфейсов уже меняется")
		return
	}
	defer s.ops.end(&s.ops.ifaceBusy)
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(ctl.IfaceTimeout + 60e9))

	out, err := s.cfg.Ctl.IfaceChange(context.WithoutCancel(r.Context()), verb, body.Name)
	if err != nil {
		opError(w, err)
		return
	}
	names, err := s.cfg.Ctl.IfaceList(r.Context())
	if err != nil {
		names = nil // the change went through; the screen asks for the list again
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out, "ifaces": names})
}
