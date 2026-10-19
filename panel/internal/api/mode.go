package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// modeGet handles GET /api/mode: the mode, the IPS method and, while a
// switch to ips waits for confirmation, the seconds before it is taken back.
func (s *server) modeGet(w http.ResponseWriter, r *http.Request) {
	st, err := s.cfg.Ctl.ModeStatus(r.Context())
	if err != nil {
		modeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

// modeSet handles POST /api/mode with {"mode":"ids|ips","acknowledged":true,
// "confirm_timeout":120}. Switching to ips can cut the host off the network
// when the rules are wrong, so the request must say it was confirmed by a
// person; the screen sets it after its own confirmation. ctl takes the mode
// back by itself unless it is confirmed in time.
func (s *server) modeSet(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Mode           string `json:"mode"`
		Acknowledged   bool   `json:"acknowledged"`
		ConfirmTimeout int    `json:"confirm_timeout"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "неверный запрос")
		return
	}
	if body.Mode != "ids" && body.Mode != "ips" {
		writeError(w, http.StatusBadRequest, "режим: ids или ips")
		return
	}
	if body.Mode == "ips" {
		if !body.Acknowledged {
			writeError(w, http.StatusBadRequest, "переключение в IPS нужно подтвердить: без подтверждения в течение отведённого времени режим вернётся в ids")
			return
		}
		if body.ConfirmTimeout != 0 && (body.ConfirmTimeout < ctl.ModeConfirmMin || body.ConfirmTimeout > ctl.ModeConfirmMax) {
			writeError(w, http.StatusBadRequest, "время подтверждения: от 10 до 3600 секунд")
			return
		}
	}
	if !s.ops.begin(&s.ops.modeBusy) {
		writeError(w, http.StatusConflict, "режим уже переключается")
		return
	}
	defer s.ops.end(&s.ops.modeBusy)
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(ctl.ModeTimeout + 60e9))

	out, err := s.cfg.Ctl.ModeSet(context.WithoutCancel(r.Context()), body.Mode, body.ConfirmTimeout)
	if err != nil {
		modeError(w, err)
		return
	}
	st, err := s.cfg.Ctl.ModeStatus(r.Context())
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out, "mode": st})
}

// modeConfirm handles POST /api/mode/confirm: keeps the ips mode.
func (s *server) modeConfirm(w http.ResponseWriter, r *http.Request) {
	if !s.ops.begin(&s.ops.modeBusy) {
		writeError(w, http.StatusConflict, "режим переключается, подождите")
		return
	}
	defer s.ops.end(&s.ops.modeBusy)
	out, err := s.cfg.Ctl.ModeConfirm(r.Context())
	if err != nil {
		modeError(w, err)
		return
	}
	st, err := s.cfg.Ctl.ModeStatus(r.Context())
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out, "mode": st})
}

// modeError adds to opError the exit code 3 of the mode commands: "not
// possible now" (nothing to confirm, the time ran out, ips needs something
// the host lacks) is a conflict with the current state, not a server fault.
func modeError(w http.ResponseWriter, err error) {
	var exit *ctl.ExitError
	if errors.As(err, &exit) && exit.Code == 3 {
		writeError(w, http.StatusConflict, errText(err))
		return
	}
	opError(w, err)
}
