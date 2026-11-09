package api

import (
	"encoding/json"
	"errors"
	"mime"
	"net/http"
	"regexp"
	"strconv"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// The exceptions of Suricata (tech.md 18.40). The screen and the CLI are the
// same thing: every route runs one `dpistack exceptions` verb, which checks
// the values, writes threshold.config, tests it with `suricata -T` and
// reloads Suricata. The checks here only keep a value that ctl would refuse
// from being sent, so the screen can say why in a sentence.
var (
	excID   = regexp.MustCompile(`^(suppress|limit):[0-9]{1,10}:(any|src|dst):[0-9A-Fa-f.:/]{1,60}$`)
	excNote = regexp.MustCompile(`^[A-Za-z0-9 ._:/@+,=-]{0,80}$`)
	excIP   = regexp.MustCompile(`^[0-9A-Fa-f.:/]{1,60}$`)
	excNum  = regexp.MustCompile(`^[0-9]{1,9}$`)
)

// exceptionsList handles GET /api/exceptions.
func (s *server) exceptionsList(w http.ResponseWriter, r *http.Request) {
	list, err := s.cfg.Ctl.Exceptions(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, list)
}

// exceptionsAdd handles POST /api/exceptions. The body mirrors the options
// of `exceptions add`: kind, sid, track, ip, count, seconds, days, never,
// note. `by` is always the signed in user, never taken from the body.
func (s *server) exceptionsAdd(w http.ResponseWriter, r *http.Request) {
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type: application/json is required")
		return
	}
	var body struct {
		Kind    string `json:"kind"`
		SID     int    `json:"sid"`
		Track   string `json:"track"`
		IP      string `json:"ip"`
		Count   int    `json:"count"`
		Seconds int    `json:"seconds"`
		Days    int    `json:"days"`
		Never   bool   `json:"never"`
		Note    string `json:"note"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return
	}
	if body.Kind != "suppress" && body.Kind != "limit" {
		writeError(w, http.StatusBadRequest, "the kind is suppress or limit")
		return
	}
	if body.SID < 1 || body.SID > 2147483647 {
		writeError(w, http.StatusBadRequest, "the rule number (sid) is a positive number")
		return
	}
	if body.Track != "" && body.Track != "src" && body.Track != "dst" {
		writeError(w, http.StatusBadRequest, "track is src or dst")
		return
	}
	if body.IP != "" && !excIP.MatchString(body.IP) {
		writeError(w, http.StatusBadRequest, "the address may hold digits, letters a to f, dots, colons and a slash")
		return
	}
	if !excNote.MatchString(body.Note) {
		writeError(w, http.StatusBadRequest, "the note is up to 80 characters: Latin letters, digits, space and . _ : / @ + , = -")
		return
	}
	if body.Never && body.Days != 0 {
		writeError(w, http.StatusBadRequest, "choose a number of days or never, not both")
		return
	}
	if body.Days < 0 || body.Count < 0 || body.Seconds < 0 {
		writeError(w, http.StatusBadRequest, "numbers cannot be negative")
		return
	}
	add := ctl.ExceptionAdd{
		Kind: body.Kind, SID: strconv.Itoa(body.SID), Track: body.Track, IP: body.IP,
		Days: ctl.FormatDays(body.Days), Never: body.Never, Note: body.Note, By: who(r).Name,
	}
	if body.Count > 0 {
		add.Count = strconv.Itoa(body.Count)
	}
	if body.Seconds > 0 {
		add.Seconds = strconv.Itoa(body.Seconds)
	}
	id, err := s.cfg.Ctl.ExceptionAdd(r.Context(), add)
	if err != nil {
		exceptionError(w, err)
		return
	}
	auditDetail(r, "exception="+id)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
}

// exceptionsRemove handles POST /api/exceptions/remove with {"id": "..."}.
// The id holds a slash for a network and colons, so it travels in the body.
func (s *server) exceptionsRemove(w http.ResponseWriter, r *http.Request) {
	if mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); mt != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type: application/json is required")
		return
	}
	var body struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return
	}
	if !excID.MatchString(body.ID) {
		writeError(w, http.StatusBadRequest, "not an exception id; take it from the list")
		return
	}
	if err := s.cfg.Ctl.ExceptionRemove(r.Context(), body.ID); err != nil {
		exceptionError(w, err)
		return
	}
	auditDetail(r, "exception="+body.ID)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// exceptionError is opError plus the two codes the exceptions verb adds:
// 2 and 5 are a value or a combination ctl refused (400 with its words), 3
// is a file that did not pass suricata -T (422, nothing was written).
func exceptionError(w http.ResponseWriter, err error) {
	var exit *ctl.ExitError
	if errors.As(err, &exit) {
		switch exit.Code {
		case 2, 5:
			writeError(w, http.StatusBadRequest, errText(err))
			return
		case 3:
			writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
				"error":  "Suricata does not accept the file with this entry; nothing was changed",
				"output": exit.Output,
			})
			return
		}
	}
	opError(w, err)
}
