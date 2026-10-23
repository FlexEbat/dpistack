package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sort"
	"strings"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// The shape of a key and a value that the panel passes on. The strict check
// of every value (the schema patterns of dpistack.conf) is ctl's; this only
// keeps what cannot be a line of KEY=VALUE out of its stdin.
var (
	settingKey = regexp.MustCompile(`^[A-Z][A-Z0-9_]{1,63}$`)
	secretKey  = regexp.MustCompile(`^[A-Z][A-Z0-9_]{1,63}$`)
)

const (
	maxSettingValue = 1024
	maxSettingPairs = 100
)

type settingsBody struct {
	Values        map[string]string `json:"values"`
	ConfirmAccess bool              `json:"confirm_access"`
}

// readSettings decodes and shapes the request: the keys come back sorted so
// that ctl sees the same order whatever the map did.
func readSettings(w http.ResponseWriter, r *http.Request) (settingsBody, []string, bool) {
	var body settingsBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "неверный запрос")
		return body, nil, false
	}
	if len(body.Values) == 0 || len(body.Values) > maxSettingPairs {
		writeError(w, http.StatusBadRequest, "нужно от 1 до 100 значений")
		return body, nil, false
	}
	keys := make([]string, 0, len(body.Values))
	for k, v := range body.Values {
		if !settingKey.MatchString(k) {
			writeError(w, http.StatusBadRequest, "недопустимое имя ключа")
			return body, nil, false
		}
		if len(v) > maxSettingValue || strings.ContainsAny(v, "\n\r\x00") {
			writeError(w, http.StatusBadRequest, k+": значение слишком длинное или с переводом строки")
			return body, nil, false
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return body, keys, true
}

// settingsList handles GET /api/settings: the schema with the values.
func (s *server) settingsList(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.SettingsList(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(out)
}

// checkAnswer is the part of `settings check` the apply handler reads.
type checkAnswer struct {
	Ok       bool            `json:"ok"`
	Weight   string          `json:"weight"`
	Changed  []string        `json:"changed"`
	Errors   []string        `json:"errors"`
	Warnings json.RawMessage `json:"warnings"`
}

// runCheck returns ctl's JSON and its parsed form; exit 3 is an answer.
func (s *server) runCheck(ctx context.Context, keys []string, values map[string]string) ([]byte, checkAnswer, error) {
	out, err := s.cfg.Ctl.SettingsCheck(ctx, keys, values)
	var exit *ctl.ExitError
	if err != nil {
		if !errors.As(err, &exit) || exit.Code != 3 {
			return nil, checkAnswer{}, err
		}
		out = []byte(exit.Output)
	}
	var a checkAnswer
	if jerr := json.Unmarshal(out, &a); jerr != nil {
		return nil, a, errors.New("ctl: настройки: непонятный ответ проверки")
	}
	return out, a, nil
}

// settingsCheck handles POST /api/settings/check: the verdict, the weight of
// the change and the busy ports, and nothing is written.
func (s *server) settingsCheck(w http.ResponseWriter, r *http.Request) {
	body, keys, ok := readSettings(w, r)
	if !ok {
		return
	}
	out, _, err := s.runCheck(r.Context(), keys, body.Values)
	if err != nil {
		opError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(out)
}

// settingsApply handles POST /api/settings/apply. The change is checked, then
// applied the way its weight needs: a light one at once (reconfigure inside
// the request), a heavy one as a unit that the screen follows through
// /api/settings/job. One change at a time.
func (s *server) settingsApply(w http.ResponseWriter, r *http.Request) {
	body, keys, ok := readSettings(w, r)
	if !ok {
		return
	}
	if !s.ops.begin(&s.ops.settingsBusy) {
		writeError(w, http.StatusConflict, "настройки уже применяются")
		return
	}
	defer s.ops.end(&s.ops.settingsBusy)
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(ctl.SettingsTimeout + 60e9))
	ctx := context.WithoutCancel(r.Context())

	_, a, err := s.runCheck(ctx, keys, body.Values)
	if err != nil {
		opError(w, err)
		return
	}
	if !a.Ok {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": "проверка не пройдена", "errors": a.Errors})
		return
	}
	if len(a.Changed) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "weight": a.Weight, "output": "без изменений"})
		return
	}
	mode := "--apply"
	if a.Weight == "heavy" {
		mode = "--apply-heavy"
	}
	out, err := s.cfg.Ctl.SettingsSet(ctx, mode, body.ConfirmAccess, keys, body.Values)
	if err != nil {
		var exit *ctl.ExitError
		if errors.As(err, &exit) && exit.Code == 3 {
			// the refusal of ctl: a busy port with a free one, a heavy change
			writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": strings.TrimSpace(exit.Output + " " + exit.Message)})
			return
		}
		opError(w, err)
		return
	}
	code := http.StatusOK
	if mode == "--apply-heavy" {
		code = http.StatusAccepted
	}
	writeJSON(w, code, map[string]any{"ok": true, "weight": a.Weight, "changed": a.Changed, "output": out})
}

// settingsSecret handles PUT /api/settings/secret/{key} with {"value":"..."};
// an empty value removes the secret. The value goes to ctl on stdin and the
// answer never repeats it.
func (s *server) settingsSecret(w http.ResponseWriter, r *http.Request) {
	key := r.PathValue("key")
	if !secretKey.MatchString(key) {
		writeError(w, http.StatusBadRequest, "недопустимое имя ключа")
		return
	}
	var body struct {
		Value string `json:"value"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "неверный запрос")
		return
	}
	if len(body.Value) > maxSettingValue || strings.ContainsAny(body.Value, "\n\r\x00") {
		writeError(w, http.StatusBadRequest, "значение слишком длинное или с переводом строки")
		return
	}
	if !s.ops.begin(&s.ops.settingsBusy) {
		writeError(w, http.StatusConflict, "настройки уже применяются")
		return
	}
	defer s.ops.end(&s.ops.settingsBusy)
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(ctl.SettingsTimeout + 60e9))
	out, err := s.cfg.Ctl.SettingsSecret(context.WithoutCancel(r.Context()), key, body.Value)
	if err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// settingsJob handles GET /api/settings/job: the state of the heavy apply.
func (s *server) settingsJob(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.SettingsJob(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(out)
}
