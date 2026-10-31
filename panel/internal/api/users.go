package api

import (
	"encoding/json"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
)

var userName = regexp.MustCompile(`^[a-z][a-z0-9_.-]{1,31}$`)

var userRoles = []string{"viewer", "analyst", "operator", "admin", "custom"}

const (
	minPassword = 8
	maxPassword = 256
)

// principal is who a request belongs to, set by authed.
type principal struct{ user auth.User }

type principalKey struct{}

func who(r *http.Request) auth.User {
	p, _ := r.Context().Value(principalKey{}).(principal)
	return p.user
}

// need is authed plus a permission: 403 {"error":"forbidden"} without it.
func (s *server) need(perm string, next http.HandlerFunc) http.HandlerFunc {
	return s.authed(func(w http.ResponseWriter, r *http.Request) {
		if !who(r).Has(perm) {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden", "permission": perm})
			return
		}
		next(w, r)
	})
}

type userView struct {
	Name     string   `json:"name"`
	Role     string   `json:"role"`
	Perms    []string `json:"perms"`
	Disabled bool     `json:"disabled"`
	Created  string   `json:"created,omitempty"`
}

func viewOf(u auth.User) userView {
	return userView{Name: u.Name, Role: u.Role, Perms: u.Effective(), Disabled: u.Disabled, Created: u.Created}
}

// me handles GET /api/me.
func (s *server) me(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, viewOf(who(r)))
}

// usersList handles GET /api/users: never a hash.
func (s *server) usersList(w http.ResponseWriter, r *http.Request) {
	list, err := s.users.List()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not read the users")
		return
	}
	out := make([]userView, 0, len(list))
	for _, u := range list {
		out = append(out, viewOf(u))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"users": out, "roles": userRoles, "permissions": auth.AllPerms,
	})
}

type userBody struct {
	Name     string   `json:"name"`
	Role     string   `json:"role"`
	Perms    []string `json:"perms"`
	Password string   `json:"password"`
	Disabled *bool    `json:"disabled"`
}

func decodeUser(w http.ResponseWriter, r *http.Request) (userBody, bool) {
	var b userBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&b); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return b, false
	}
	return b, true
}

func checkRole(w http.ResponseWriter, b userBody) bool {
	if !slices.Contains(userRoles, b.Role) {
		writeError(w, http.StatusBadRequest, "the role is one of: "+strings.Join(userRoles, ", "))
		return false
	}
	if b.Role == "custom" {
		if len(b.Perms) == 0 {
			writeError(w, http.StatusBadRequest, "the role custom needs a list of permissions")
			return false
		}
		for _, p := range b.Perms {
			if !slices.Contains(auth.AllPerms, p) {
				writeError(w, http.StatusBadRequest, "unknown permission: "+p)
				return false
			}
		}
	}
	return true
}

func checkPassword(w http.ResponseWriter, pw string) bool {
	n := utf8.RuneCountInString(pw)
	if n < minPassword || n > maxPassword || strings.ContainsAny(pw, "\r\n") {
		writeError(w, http.StatusBadRequest, "the password has 8 to 256 characters and one line")
		return false
	}
	return true
}

// usersCreate handles POST /api/users.
func (s *server) usersCreate(w http.ResponseWriter, r *http.Request) {
	b, ok := decodeUser(w, r)
	if !ok {
		return
	}
	if !userName.MatchString(b.Name) {
		writeError(w, http.StatusBadRequest, "the name has 2 to 32 characters: a letter first, then letters, digits, dot, hyphen or underscore (lower case)")
		return
	}
	if !checkRole(w, b) || !checkPassword(w, b.Password) {
		return
	}
	if _, err := s.cfg.Ctl.UsersAdd(r.Context(), b.Name, b.Role, b.Perms, b.Password); err != nil {
		ctlError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]bool{"ok": true})
}

// usersChange handles PUT /api/users/{name}: a role, a password and the
// disabled flag, whichever are in the body.
func (s *server) usersChange(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !userName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "bad user name")
		return
	}
	b, ok := decodeUser(w, r)
	if !ok {
		return
	}
	self := who(r).Name == name
	if self && b.Disabled != nil && *b.Disabled {
		writeError(w, http.StatusConflict, "you cannot disable your own account")
		return
	}
	if b.Role != "" && !checkRole(w, b) {
		return
	}
	if b.Password != "" && !checkPassword(w, b.Password) {
		return
	}
	if b.Role == "" && b.Password == "" && b.Disabled == nil {
		writeError(w, http.StatusBadRequest, "nothing to change")
		return
	}
	// A new role is applied first: the last-manager guard of dpistack refuses
	// it before anything else is touched.
	if b.Role != "" {
		if _, err := s.cfg.Ctl.UsersRole(r.Context(), name, b.Role, b.Perms); err != nil {
			ctlError(w, err)
			return
		}
	}
	if b.Password != "" {
		if _, err := s.cfg.Ctl.UsersPasswd(r.Context(), name, b.Password); err != nil {
			ctlError(w, err)
			return
		}
	}
	if b.Disabled != nil {
		action := "enable"
		if *b.Disabled {
			action = "disable"
		}
		if _, err := s.cfg.Ctl.UsersState(r.Context(), action, name); err != nil {
			ctlError(w, err)
			return
		}
	}
	s.sessions.DeleteUser(name)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// usersDelete handles DELETE /api/users/{name}.
func (s *server) usersDelete(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !userName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "bad user name")
		return
	}
	if who(r).Name == name {
		writeError(w, http.StatusConflict, "you cannot remove your own account")
		return
	}
	if _, err := s.cfg.Ctl.UsersState(r.Context(), "remove", name); err != nil {
		ctlError(w, err)
		return
	}
	s.sessions.DeleteUser(name)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// mePassword handles POST /api/me/password: a user changes their own
// password with the current one; the sessions of the user end.
func (s *server) mePassword(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&b); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return
	}
	if !checkPassword(w, b.New) {
		return
	}
	me := who(r)
	if _, good, err := s.users.Login(me.Name, b.Current); err != nil || !good {
		writeError(w, http.StatusForbidden, "the current password is wrong")
		return
	}
	if _, err := s.cfg.Ctl.UsersPasswd(r.Context(), me.Name, b.New); err != nil {
		ctlError(w, err)
		return
	}
	s.sessions.DeleteUser(me.Name)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
