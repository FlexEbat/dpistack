package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// Rules v2 (tech.md 18.41). The routes run one verb each and send its JSON on
// as it is; the screen and `dpistack rules-stats` and friends therefore show
// the same numbers.
var (
	findClass  = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
	findSource = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$`)
	sidNumber  = regexp.MustCompile(`^[0-9]{1,10}$`)
	versionID  = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z(\.[0-9]+)?$`)
)

// passJSON sends what a verb printed, after checking that it is JSON: a verb
// that printed something else is a server error, not an answer.
func passJSON(w http.ResponseWriter, out []byte) {
	if !json.Valid(out) {
		writeError(w, http.StatusInternalServerError, "the command did not answer with JSON")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(out)
}

// rulesStats handles GET /api/rules/stats.
func (s *server) rulesStats(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.RulesStats(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// rulesHistory handles GET /api/rules/history.
func (s *server) rulesHistory(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.RulesHistory(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// rulesDescribe handles GET /api/rules/describe?sids=1,2,3 (up to 20).
func (s *server) rulesDescribe(w http.ResponseWriter, r *http.Request) {
	raw := strings.TrimSpace(r.URL.Query().Get("sids"))
	if raw == "" {
		writeError(w, http.StatusBadRequest, "sids is a list of rule numbers separated by commas")
		return
	}
	sids := strings.Split(raw, ",")
	if len(sids) > 20 {
		writeError(w, http.StatusBadRequest, "at most 20 rule numbers at a time")
		return
	}
	for _, sid := range sids {
		if !sidNumber.MatchString(sid) {
			writeError(w, http.StatusBadRequest, "a rule number is digits only")
			return
		}
	}
	out, err := s.cfg.Ctl.RulesDescribe(r.Context(), sids)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// rulesLocalCheck handles POST /api/rules/local/check: the body is the
// candidate local.rules as text, the answer is what `rules-local check`
// found. Nothing is written; saving is PUT /api/config/local.rules.
func (s *server) rulesLocalCheck(w http.ResponseWriter, r *http.Request) {
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
	out, err := s.cfg.Ctl.RulesLocalCheck(r.Context(), body)
	if err != nil {
		configError(w, err)
		return
	}
	passJSON(w, out)
}

// configHistory handles GET /api/config/{name}/history.
func (s *server) configHistory(w http.ResponseWriter, r *http.Request) {
	name, ok := configName(w, r)
	if !ok {
		return
	}
	out, err := s.cfg.Ctl.ConfigHistory(r.Context(), name)
	if err != nil {
		configError(w, err)
		return
	}
	passJSON(w, out)
}

// configVersion handles GET /api/config/{name}/history/{id}: one saved
// version of a file, so the screen can show what changed.
func (s *server) configVersion(w http.ResponseWriter, r *http.Request) {
	name, ok := configName(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if !versionID.MatchString(id) {
		writeError(w, http.StatusBadRequest, "not a version id; take it from the history")
		return
	}
	text, err := s.cfg.Ctl.ConfigVersion(r.Context(), name, id)
	if err != nil {
		configError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"name": name, "id": id, "content": text})
}

// rulesFind handles GET /api/rules/find?class=&source=&state=&q=: rules by
// category, source, state and text, disabled ones included. At least one
// filter is needed.
func (s *server) rulesFind(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	o := ctl.RulesFindOptions{
		Class:  strings.TrimSpace(q.Get("class")),
		Source: strings.TrimSpace(q.Get("source")),
		State:  strings.TrimSpace(q.Get("state")),
		Text:   strings.TrimSpace(q.Get("q")),
	}
	if o.State == "any" {
		o.State = ""
	}
	if o.Class == "" && o.Source == "" && o.State == "" && o.Text == "" {
		writeError(w, http.StatusBadRequest, "choose a category, a source, a state or enter some text")
		return
	}
	if o.Class != "" && !findClass.MatchString(o.Class) {
		writeError(w, http.StatusBadRequest, "a category is letters, digits and hyphens")
		return
	}
	if o.Source != "" && !findSource.MatchString(o.Source) {
		writeError(w, http.StatusBadRequest, "that is not a source name")
		return
	}
	if o.State != "" && o.State != "enabled" && o.State != "disabled" {
		writeError(w, http.StatusBadRequest, "the state is enabled, disabled or any")
		return
	}
	if o.Text != "" && !searchQuery.MatchString(o.Text) {
		writeError(w, http.StatusBadRequest, "the text may contain Latin letters, digits, space and the characters . _ : = / @ + , - (up to 100 characters)")
		return
	}
	out, err := s.cfg.Ctl.RulesFind(r.Context(), o)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// rulesFacets handles GET /api/rules/facets.
func (s *server) rulesFacets(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.RulesFacets(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}
