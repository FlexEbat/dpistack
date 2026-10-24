package api

import (
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// maxConfigBody is the largest config the editor accepts.
const maxConfigBody = 1 << 20

// writeAllowance is how long a save may take: `suricata -T` loads the whole
// ruleset and --apply may restart a component. It is longer than the
// server's WriteTimeout, which would otherwise cut the answer off.
const writeAllowance = 4 * time.Minute

// configNames are the files the editor may touch, in the order of the
// screen. It is the list dpistack knows (4.5), repeated here so a name
// outside it is refused before any privileged call is made.
var configNames = []string{
	"dpistack.conf", "suricata.yaml", "local.rules", "enable.conf",
	"disable.conf", "modify.conf", "drop.conf", "ntopng.conf", "evebox.yaml",
}

func knownConfig(name string) bool {
	for _, n := range configNames {
		if n == name {
			return true
		}
	}
	return false
}

// configName reads {name} and answers 404 itself when it is not on the list.
func configName(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("name")
	if !knownConfig(name) {
		writeError(w, http.StatusNotFound, "no such config file")
		return "", false
	}
	return name, true
}

// configList handles GET /api/config.
func (s *server) configList(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"names": configNames})
}

// configGet handles GET /api/config/{name}.
func (s *server) configGet(w http.ResponseWriter, r *http.Request) {
	name, ok := configName(w, r)
	if !ok {
		return
	}
	text, err := s.cfg.Ctl.ConfigRead(r.Context(), name)
	if err != nil {
		configError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "content": text})
}

// configPut handles PUT /api/config/{name}?apply=0|1: save, and with apply=1
// apply too. The checker runs first inside ctl, so a file that fails it is
// left as it was.
func (s *server) configPut(w http.ResponseWriter, r *http.Request) {
	name, ok := configName(w, r)
	if !ok {
		return
	}
	mode := ""
	switch r.URL.Query().Get("apply") {
	case "", "0":
	case "1":
		mode = "--apply"
	default:
		writeError(w, http.StatusBadRequest, "apply: 0 or 1")
		return
	}
	s.configWrite(w, r, name, mode)
}

// configCheck handles POST /api/config/{name}/check: the same check a save
// runs, with nothing saved.
func (s *server) configCheck(w http.ResponseWriter, r *http.Request) {
	name, ok := configName(w, r)
	if !ok {
		return
	}
	s.configWrite(w, r, name, "--check")
}

func (s *server) configWrite(w http.ResponseWriter, r *http.Request, name, mode string) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxConfigBody))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "the file is larger than 1 MB")
			return
		}
		writeError(w, http.StatusBadRequest, "could not read the request body")
		return
	}
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(writeAllowance))

	out, err := s.cfg.Ctl.ConfigWrite(r.Context(), name, mode, body)
	if err != nil {
		configError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// configRevert handles POST /api/config/{name}/revert.
func (s *server) configRevert(w http.ResponseWriter, r *http.Request) {
	name, ok := configName(w, r)
	if !ok {
		return
	}
	out, err := s.cfg.Ctl.ConfigRevert(r.Context(), name)
	if err != nil {
		configError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// configError is ctlError for the editor, where exit 3 means the checker or
// the apply step refused (a failed check, or a change too heavy for
// reconfigure): 422 with ctl's text and the checker's own output. Exit 4 is a
// component that is not installed, which is a conflict with the system and
// not a missing path.
func configError(w http.ResponseWriter, err error) {
	var exit *ctl.ExitError
	if errors.As(err, &exit) {
		switch exit.Code {
		case 3:
			writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
				"error":  errText(err),
				"output": exit.Output,
			})
			return
		case 4:
			writeError(w, http.StatusConflict, errText(err))
			return
		}
	}
	ctlError(w, err)
}
