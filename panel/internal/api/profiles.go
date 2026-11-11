package api

import (
	"net/http"
	"regexp"
)

// Settings profiles (tech.md 18.44). A profile is a named set of KEY=VALUE
// pairs; the verbs keep the file and check the values. A profile is applied
// by the screen loading its values into the edits, so it goes through the
// same check, diff and apply as any change; there is no route that applies a
// profile by itself.
var profileName = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// profilesList handles GET /api/settings/profiles.
func (s *server) profilesList(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.SettingsProfileList(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// profileShow handles GET /api/settings/profiles/{name}.
func (s *server) profileShow(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !profileName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "a profile name is 1 to 32 lowercase letters, digits, - and _")
		return
	}
	out, err := s.cfg.Ctl.SettingsProfileShow(r.Context(), name)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// profileSave handles PUT /api/settings/profiles/{name} with {"values":{...}}.
// The shape of the body is that of the other settings routes.
func (s *server) profileSave(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !profileName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "a profile name is 1 to 32 lowercase letters, digits, - and _")
		return
	}
	body, keys, ok := readSettings(w, r)
	if !ok {
		return
	}
	auditDetail(r, "save "+name)
	if err := s.cfg.Ctl.SettingsProfileSave(r.Context(), name, who(r).Name, keys, body.Values); err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// profileDelete handles DELETE /api/settings/profiles/{name}.
func (s *server) profileDelete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !profileName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "a profile name is 1 to 32 lowercase letters, digits, - and _")
		return
	}
	auditDetail(r, "delete "+name)
	if err := s.cfg.Ctl.SettingsProfileDelete(r.Context(), name, who(r).Name); err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
