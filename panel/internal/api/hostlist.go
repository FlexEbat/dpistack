package api

import (
	"encoding/json"
	"mime"
	"net/http"
	"regexp"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// The block and allow lists of hosts. The screen and the CLI are the same
// thing: every route runs one `dpistack ips block|allow` verb, which checks
// the address, writes local.rules, tests it with `suricata -T` and applies it.
var (
	hostWhat = regexp.MustCompile(`^([0-9]{1,10}|[0-9A-Fa-f.:/]{1,60})$`)
	hostAddr = regexp.MustCompile(`^[0-9A-Fa-f.:/]{1,60}$`)
)

func hostKindOK(k string) bool { return k == "block" || k == "allow" }

// hostList handles GET /api/ips/{kind}.
func (s *server) hostList(w http.ResponseWriter, r *http.Request) {
	kind := r.PathValue("kind")
	if !hostKindOK(kind) {
		writeError(w, http.StatusNotFound, "the lists are block and allow")
		return
	}
	list, err := s.cfg.Ctl.HostList(r.Context(), kind)
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"kind": kind, "entries": list})
}

// hostAdd handles POST /api/ips/{kind} with {address, days, note}. `by` is
// the signed in user, never taken from the body.
func (s *server) hostAdd(w http.ResponseWriter, r *http.Request) {
	kind := r.PathValue("kind")
	if !hostKindOK(kind) {
		writeError(w, http.StatusNotFound, "the lists are block and allow")
		return
	}
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type: application/json is required")
		return
	}
	var body struct {
		Address string `json:"address"`
		Days    int    `json:"days"`
		Note    string `json:"note"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return
	}
	if !hostAddr.MatchString(body.Address) {
		writeError(w, http.StatusBadRequest, "the address may hold digits, letters a to f, dots, colons and a slash")
		return
	}
	if !excNote.MatchString(body.Note) {
		writeError(w, http.StatusBadRequest, "the note is up to 80 characters: Latin letters, digits, space and . _ : / @ + , = -")
		return
	}
	if body.Days < 0 {
		writeError(w, http.StatusBadRequest, "days cannot be negative")
		return
	}
	out, err := s.cfg.Ctl.HostAdd(r.Context(), ctl.HostAdd{
		Kind: kind, Address: body.Address, Days: ctl.FormatDays(body.Days), Note: body.Note, By: who(r).Name,
	})
	if err != nil {
		exceptionError(w, err)
		return
	}
	auditDetail(r, kind+"="+body.Address)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// hostRemove handles POST /api/ips/{kind}/remove with {"what": address or sid}.
func (s *server) hostRemove(w http.ResponseWriter, r *http.Request) {
	kind := r.PathValue("kind")
	if !hostKindOK(kind) {
		writeError(w, http.StatusNotFound, "the lists are block and allow")
		return
	}
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type: application/json is required")
		return
	}
	var body struct {
		What string `json:"what"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return
	}
	if !hostWhat.MatchString(body.What) {
		writeError(w, http.StatusBadRequest, "an address or a sid from the list is needed")
		return
	}
	if err := s.cfg.Ctl.HostRemove(r.Context(), kind, body.What); err != nil {
		exceptionError(w, err)
		return
	}
	auditDetail(r, kind+"="+body.What+" removed")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
