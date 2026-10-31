package auth

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"strings"
)

// The permissions of the panel (tech.md 4.5, slice 34). A route names one.
const (
	PermView             = "view"
	PermEventsAck        = "events.ack"
	PermTestsRun         = "tests.run"
	PermComponentsCtl    = "components.control"
	PermRulesEdit        = "rules.edit"
	PermSettingsEdit     = "settings.edit"
	PermConfigsEdit      = "configs.edit"
	PermIPSManage        = "ips.manage"
	PermBackupManage     = "backup.manage"
	PermUpdateManage     = "update.manage"
	PermAuditView        = "audit.view"
	PermUsersManage      = "users.manage"
	roleCustom           = "custom"
	legacyAdmin          = "admin"
	maxUsersFile         = 1 << 20
	DefaultLoginUsername = legacyAdmin
)

// AllPerms is the catalog, in the order of the documents.
var AllPerms = []string{
	PermView, PermEventsAck, PermTestsRun, PermComponentsCtl, PermRulesEdit,
	PermSettingsEdit, PermConfigsEdit, PermIPSManage, PermBackupManage,
	PermUpdateManage, PermAuditView, PermUsersManage,
}

// rolePerms are the presets; `dpistack users` keeps the same table
// (tests compare both with testdata/presets.json).
var rolePerms = map[string][]string{
	"viewer":   {PermView},
	"analyst":  {PermView, PermEventsAck, PermTestsRun, PermAuditView},
	"operator": {PermView, PermEventsAck, PermTestsRun, PermAuditView, PermComponentsCtl, PermRulesEdit},
	"admin":    AllPerms,
}

// RolePerms returns the permissions of a preset role, nil for an unknown one.
func RolePerms(role string) []string {
	return slices.Clone(rolePerms[role])
}

// User is one account of users.json.
type User struct {
	Name     string   `json:"name"`
	Role     string   `json:"role"`
	Perms    []string `json:"perms,omitempty"`
	Hash     string   `json:"hash"`
	Created  string   `json:"created,omitempty"`
	Disabled bool     `json:"disabled,omitempty"`
}

// Effective returns what the user may do: the preset of the role, or the own
// list of a custom user.
func (u User) Effective() []string {
	if u.Role == roleCustom {
		return slices.Clone(u.Perms)
	}
	return RolePerms(u.Role)
}

// Has reports whether the user holds a permission.
func (u User) Has(perm string) bool {
	return slices.Contains(u.Effective(), perm)
}

// ErrNoUsers means there is neither users.json nor a panel password.
var ErrNoUsers = errors.New("auth: no users")

// Users reads the accounts. users.json is the source; when it is not there
// the old panel.auth is the password of the one user, admin (an upgrade from
// the one-password panel works with no step in between).
type Users struct {
	File   string // users.json
	Legacy string // panel.auth
}

// List returns every account.
func (s *Users) List() ([]User, error) {
	data, err := os.ReadFile(s.File)
	if errors.Is(err, fs.ErrNotExist) {
		return s.legacyList()
	}
	if err != nil {
		return nil, fmt.Errorf("read users.json: %w", err)
	}
	if len(data) > maxUsersFile {
		return nil, errors.New("users.json is too large")
	}
	var doc struct {
		Users []User `json:"users"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("users.json is damaged: %w", err)
	}
	return doc.Users, nil
}

func (s *Users) legacyList() ([]User, error) {
	if s.Legacy == "" {
		return nil, ErrNoUsers
	}
	data, err := os.ReadFile(s.Legacy)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrNoUsers
	}
	if err != nil {
		return nil, fmt.Errorf("read panel.auth: %w", err)
	}
	phc := strings.TrimSpace(string(data))
	if phc == "" {
		return nil, ErrNoUsers
	}
	return []User{{Name: legacyAdmin, Role: legacyAdmin, Hash: phc}}, nil
}

// Find returns an enabled account by name.
func (s *Users) Find(name string) (User, bool, error) {
	list, err := s.List()
	if err != nil {
		return User{}, false, err
	}
	for _, u := range list {
		if u.Name == name && !u.Disabled {
			return u, true, nil
		}
	}
	return User{}, false, nil
}

// dummyHash is checked when the user name is unknown, so that a wrong name
// and a wrong password take the same time and give the same answer. It is a
// valid hash (m=16384, t=3, p=4) of a random password nobody knows.
const dummyHash = "$argon2id$v=19$m=16384,t=3,p=4$ZHBpc3RhY2stZHVtbXk$Tx5N0N5qK0m3mO1eYb3g7y3n5xYk9mN1z2WqQnq4t9E"

// Login checks the user and the password. A wrong user, a disabled user and a
// wrong password all return (User{}, false, nil).
func (s *Users) Login(name, password string) (User, bool, error) {
	u, found, err := s.Find(name)
	if err != nil {
		return User{}, false, err
	}
	hash := u.Hash
	if !found {
		hash = dummyHash
	}
	good, err := Verify(hash, password)
	if err != nil {
		if !found && errors.Is(err, ErrHashFormat) {
			return User{}, false, nil
		}
		return User{}, false, err
	}
	if !good || !found {
		return User{}, false, nil
	}
	return u, true, nil
}
