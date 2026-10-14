package api

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// componentID is only a sanity filter on the path: which components exist
// is for dpistack-ctl to say (tech.md 4.1), not a list copied here.
var componentID = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// control handles POST /api/components/{id}/{start|stop|restart}.
//
// Stopping or restarting the panel from the panel needs a second, separate
// confirmation (?confirm=yes), and runs after the answer has been sent: the
// command ends this very process, so an answer written afterwards would never
// reach the browser.
func (s *server) control(w http.ResponseWriter, r *http.Request) {
	id, action := r.PathValue("id"), r.PathValue("action")
	if !componentID.MatchString(id) || (action != "start" && action != "stop" && action != "restart") {
		writeError(w, http.StatusNotFound, "нет такого компонента или действия")
		return
	}

	if id == "panel" && action != "start" {
		if r.URL.Query().Get("confirm") != "yes" {
			writeJSON(w, http.StatusConflict, map[string]any{
				"error":            "это остановит саму панель, нужно отдельное подтверждение",
				"confirm_required": true,
			})
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{
			"ok":       true,
			"detached": true,
			"output":   "команда отправлена, панель сейчас перезапустится или остановится",
		})
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		go func() {
			time.Sleep(300 * time.Millisecond) // let the answer leave first
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			if _, err := s.cfg.Ctl.Control(ctx, action, id); err != nil {
				log.Printf("components: %s %s: %v", action, id, err)
			}
		}()
		return
	}

	out, err := s.cfg.Ctl.Control(r.Context(), action, id)
	if err != nil {
		ctlError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// reloadSuricata handles POST /api/suricata/reload.
func (s *server) reloadSuricata(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.ReloadSuricata(r.Context())
	if err != nil {
		ctlError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// ctlError turns what dpistack-ctl said into an HTTP answer with the text
// it gave: 4 and 5 (no such component) are 404, 2 is 400, 3 is 409, any
// other failure is 500; ctl not running at all is 502.
func ctlError(w http.ResponseWriter, err error) {
	var exit *ctl.ExitError
	if errors.As(err, &exit) {
		text := errText(err)
		switch exit.Code {
		case 4, 5:
			writeError(w, http.StatusNotFound, text)
		case 2:
			writeError(w, http.StatusBadRequest, text)
		case 3:
			writeError(w, http.StatusConflict, text)
		default:
			writeError(w, http.StatusInternalServerError, text)
		}
		return
	}
	writeError(w, http.StatusBadGateway, errText(err))
}

// errText is the sentence shown to the user for an error from ctl.
func errText(err error) string {
	var exit *ctl.ExitError
	if errors.As(err, &exit) {
		if exit.Message != "" {
			return exit.Message
		}
		return fmt.Sprintf("dpistack-ctl завершился с кодом %d", exit.Code)
	}
	return "dpistack-ctl недоступен: " + strings.TrimPrefix(err.Error(), ctl.ErrUnavailable.Error()+": ")
}
