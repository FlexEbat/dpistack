package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// updateAllowance is how long the answer to a rules update may take to
// write: longer than ctl.UpdateTimeout and the server's WriteTimeout.
const updateAllowance = ctl.UpdateTimeout + time.Minute

// The patterns repeat what dpistack-ctl accepts (4.5), so a bad value is
// refused with a readable sentence before any privileged call. ctl still has
// the last word.
var (
	sourceName  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$`)
	sourceURL   = regexp.MustCompile(`^https?://[A-Za-z0-9._:/@+,=-]{1,500}$`)
	groupName   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`)
	ruleSID     = regexp.MustCompile(`^[0-9]{1,10}$`)
	searchQuery = regexp.MustCompile(`^[A-Za-z0-9._:=/@+, -]{1,100}$`)
)

// updateResult is what the screen shows after an update.
type updateResult struct {
	Time   string `json:"time"`
	OK     bool   `json:"ok"`
	Error  string `json:"error,omitempty"`
	Output string `json:"output"`
}

// rulesState remembers the last update started from this panel. The timer
// updates through suricata-update directly and suricata-update leaves the
// ruleset file untouched when nothing changed, so neither leaves a time the
// panel could read; the record is lost when the panel restarts.
type rulesState struct {
	mu       sync.Mutex
	last     *updateResult
	updating bool
}

func (rs *rulesState) snapshot() (*updateResult, bool) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return rs.last, rs.updating
}

// begin claims the single update slot; false means one is already running.
func (rs *rulesState) begin() bool {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	if rs.updating {
		return false
	}
	rs.updating = true
	return true
}

func (rs *rulesState) finish(res *updateResult) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	rs.updating = false
	rs.last = res
}

// rulesSources handles GET /api/rules/sources.
func (s *server) rulesSources(w http.ResponseWriter, r *http.Request) {
	list, err := s.cfg.Ctl.RulesSources(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	last, updating := s.rules.snapshot()
	writeJSON(w, http.StatusOK, map[string]any{
		"sources":     list,
		"last_update": last,
		"updating":    updating,
	})
}

// rulesSourceChange handles POST /api/rules/sources with
// {"action":"enable|disable|remove","name":"..."} or
// {"action":"add-url","url":"..."}.
func (s *server) rulesSourceChange(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
		Name   string `json:"name"`
		URL    string `json:"url"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "неверный запрос")
		return
	}
	var arg string
	switch body.Action {
	case "enable", "disable", "remove":
		if !sourceName.MatchString(body.Name) {
			writeError(w, http.StatusBadRequest, "недопустимое имя источника")
			return
		}
		arg = body.Name
	case "add-url":
		if !sourceURL.MatchString(body.URL) {
			writeError(w, http.StatusBadRequest, "адрес должен начинаться с http:// или https://; знаки ? & % и кавычки в адресе не поддерживаются")
			return
		}
		arg = body.URL
	default:
		writeError(w, http.StatusBadRequest, "action: enable, disable, remove или add-url")
		return
	}
	out, err := s.cfg.Ctl.RulesSource(r.Context(), body.Action, arg)
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// rulesUpdate handles POST /api/rules/update.
//
// ctl runs detached from the request: if the browser leaves halfway, killing
// the update would skip ctl's own rollback and could leave a half-written
// ruleset. One update runs at a time.
func (s *server) rulesUpdate(w http.ResponseWriter, r *http.Request) {
	if !s.rules.begin() {
		writeError(w, http.StatusConflict, "обновление правил уже идёт")
		return
	}
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(updateAllowance))

	out, err := s.cfg.Ctl.RulesUpdate(context.WithoutCancel(r.Context()))
	res := &updateResult{Time: s.cfg.Now().UTC().Format(time.RFC3339), OK: err == nil, Output: out}
	if err != nil {
		res.Error = errText(err)
		var exit *ctl.ExitError
		if errors.As(err, &exit) {
			res.Output = exit.Output
		}
	}
	s.rules.finish(res)

	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out, "last_update": res})
}

// rulesSearch handles GET /api/rules/search?q=.
func (s *server) rulesSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeError(w, http.StatusBadRequest, "введите sid или часть текста правила")
		return
	}
	if !searchQuery.MatchString(q) {
		writeError(w, http.StatusBadRequest, "в запросе допустимы латинские буквы, цифры, пробел и знаки . _ : = / @ + , - (до 100 знаков)")
		return
	}
	rules, err := s.cfg.Ctl.RulesSearch(r.Context(), q)
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"results":   rules,
		"truncated": len(rules) == ctl.MaxSearchResults,
	})
}

// rulesGroup handles POST /api/rules/groups/{group}/{enable|disable}.
func (s *server) rulesGroup(w http.ResponseWriter, r *http.Request) {
	group, action := r.PathValue("group"), r.PathValue("action")
	if !groupName.MatchString(group) || (action != "enable" && action != "disable") {
		writeError(w, http.StatusNotFound, "нет такой группы или действия")
		return
	}
	out, err := s.cfg.Ctl.RulesGroup(r.Context(), action, group)
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// rulesSID handles POST /api/rules/sid/{sid}/{enable|disable}.
func (s *server) rulesSID(w http.ResponseWriter, r *http.Request) {
	sid, action := r.PathValue("sid"), r.PathValue("action")
	if !ruleSID.MatchString(sid) || (action != "enable" && action != "disable") {
		writeError(w, http.StatusNotFound, "нет такого правила или действия")
		return
	}
	out, err := s.cfg.Ctl.RulesSID(r.Context(), action, sid)
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// opError is ctlError for the screens that run long or editing commands
// (rules, tests, interfaces). Here exit 5 is a value ctl refused (400, not
// a missing path), exit 4 is a tool or file missing on this host (409), and
// exit 1 is a failed operation, whose reason ctl printed on stdout (500
// with it in output).
func opError(w http.ResponseWriter, err error) {
	var exit *ctl.ExitError
	if errors.As(err, &exit) {
		switch exit.Code {
		case 1:
			writeJSON(w, http.StatusInternalServerError, map[string]any{
				"error":  errText(err),
				"output": exit.Output,
			})
			return
		case 4:
			writeError(w, http.StatusConflict, errText(err))
			return
		case 5:
			writeError(w, http.StatusBadRequest, errText(err))
			return
		}
	}
	ctlError(w, err)
}
