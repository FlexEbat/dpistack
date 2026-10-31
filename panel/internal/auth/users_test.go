package auth

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// The golden table is shared with tests/users.bats, which compares it with
// what `dpistack users` prints: the shell and the panel cannot drift apart.
func TestRolePermissionsEqualTheGoldenTable(t *testing.T) {
	data, err := os.ReadFile("testdata/presets.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden struct {
		Perms []string            `json:"perms"`
		Roles map[string][]string `json:"roles"`
	}
	if err := json.Unmarshal(data, &golden); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(golden.Perms, AllPerms) {
		t.Errorf("catalog: %v, golden %v", AllPerms, golden.Perms)
	}
	for role, want := range golden.Roles {
		got := RolePerms(role)
		slices.Sort(got)
		want = slices.Clone(want)
		slices.Sort(want)
		if !slices.Equal(got, want) {
			t.Errorf("%s: %v, golden %v", role, got, want)
		}
	}
	if len(golden.Roles) != len(rolePerms) {
		t.Errorf("roles: %d in the panel, %d in the golden table", len(rolePerms), len(golden.Roles))
	}
}

func TestAViewerHoldsOnlyView(t *testing.T) {
	u := User{Name: "v", Role: "viewer"}
	for _, p := range AllPerms {
		if u.Has(p) != (p == PermView) {
			t.Errorf("viewer Has(%s) = %v", p, u.Has(p))
		}
	}
}

func TestACustomUserHasExactlyItsList(t *testing.T) {
	u := User{Name: "c", Role: "custom", Perms: []string{PermView, PermRulesEdit}}
	if !u.Has(PermRulesEdit) || u.Has(PermSettingsEdit) {
		t.Errorf("effective: %v", u.Effective())
	}
	if (User{Name: "x", Role: "nonsense"}).Has(PermView) {
		t.Error("an unknown role holds a permission")
	}
}

func TestWithoutUsersJSONThePanelAuthIsTheUserAdmin(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(dir, "panel.auth")
	const hash = "$argon2id$v=19$m=16384,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$06P4n5MT+1p4xkEaN81bac/LFLj2y/TdZ8HFiBx7mOc"
	if err := os.WriteFile(legacy, []byte(hash+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	s := &Users{File: filepath.Join(dir, "users.json"), Legacy: legacy}
	u, ok, err := s.Login("admin", "correct horse")
	if err != nil || !ok || !u.Has(PermUsersManage) {
		t.Fatalf("login: %v %v %+v", err, ok, u)
	}
	if _, ok, _ := s.Login("someone", "correct horse"); ok {
		t.Error("a name that is not there signed in")
	}
	if _, ok, _ := s.Login("admin", "wrong"); ok {
		t.Error("a wrong password signed in")
	}
}

func TestNoFilesMeansNoUsers(t *testing.T) {
	s := &Users{File: filepath.Join(t.TempDir(), "users.json"), Legacy: filepath.Join(t.TempDir(), "panel.auth")}
	if _, _, err := s.Login("admin", "x"); err != ErrNoUsers {
		t.Errorf("err = %v, want ErrNoUsers", err)
	}
}

func TestADamagedUsersFileIsAnErrorNotAnOpenDoor(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "users.json")
	if err := os.WriteFile(file, []byte("{not json"), 0o640); err != nil {
		t.Fatal(err)
	}
	s := &Users{File: file}
	if _, ok, err := s.Login("admin", "x"); ok || err == nil {
		t.Errorf("ok=%v err=%v", ok, err)
	}
}

func TestTheDummyHashIsAValidHash(t *testing.T) {
	// If it were not, an unknown name would answer faster than a wrong
	// password and tell an attacker which names exist.
	if _, err := Verify(dummyHash, "anything"); err != nil {
		t.Fatalf("dummy hash: %v", err)
	}
}

func TestSessionsKnowTheirUserAndEndByUser(t *testing.T) {
	now := mustNow()
	s := NewSessions(3600e9, func() timeT { return now })
	a, _ := s.CreateFor("ann")
	b, _ := s.CreateFor("bob")
	if u, ok := s.Who(a); !ok || u != "ann" {
		t.Errorf("Who = %q %v", u, ok)
	}
	s.DeleteUser("ann")
	if _, ok := s.Who(a); ok {
		t.Error("the session of ann is alive")
	}
	if _, ok := s.Who(b); !ok {
		t.Error("the session of bob ended")
	}
}

type timeT = time.Time

func mustNow() time.Time { return time.Unix(1_700_000_000, 0) }
