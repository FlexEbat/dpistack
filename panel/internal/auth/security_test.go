package auth

import (
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestSessionListShowsHandlesAndMetadataNotIds(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	s := NewSessions(time.Hour, func() time.Time { return now })
	id1, _ := s.CreateMeta("ann", "10.0.0.1", "Firefox\x00\n on Linux")
	now = now.Add(time.Minute)
	id2, _ := s.CreateMeta("ann", "10.0.0.2", "curl")
	s.CreateMeta("bob", "10.0.0.3", "x")
	list := s.List("ann")
	if len(list) != 2 || list[0].IP != "10.0.0.2" || list[1].IP != "10.0.0.1" {
		t.Fatalf("newest first, only ann's: %+v", list)
	}
	if list[0].Handle != Handle(id2) || strings.Contains(list[0].Handle, id2) || len(list[0].Handle) != 16 {
		t.Errorf("a handle is a short hash, not the id: %q", list[0].Handle)
	}
	if list[1].UserAgent != "Firefox on Linux" {
		t.Errorf("control characters are dropped: %q", list[1].UserAgent)
	}
	if len(s.List("")) != 3 {
		t.Errorf("an empty user lists everyone")
	}
	if Handle(id1) == Handle(id2) {
		t.Errorf("handles of two sessions must differ")
	}
}

func TestSessionUserAgentIsCut(t *testing.T) {
	s := NewSessions(time.Hour, time.Now)
	s.CreateMeta("ann", "", strings.Repeat("é", 500))
	if got := []rune(s.List("ann")[0].UserAgent); len(got) != 120 {
		t.Errorf("120 characters at most: %d", len(got))
	}
}

func TestSessionRevoke(t *testing.T) {
	s := NewSessions(time.Hour, time.Now)
	a1, _ := s.CreateMeta("ann", "", "")
	a2, _ := s.CreateMeta("ann", "", "")
	b1, _ := s.CreateMeta("bob", "", "")
	if s.RevokeHandle("ann", Handle(b1)) {
		t.Errorf("a user may not end another user's session")
	}
	if _, ok := s.Who(b1); !ok {
		t.Errorf("bob's session is untouched")
	}
	if !s.RevokeHandle("ann", Handle(a1)) {
		t.Errorf("ann ends her own")
	}
	if _, ok := s.Who(a1); ok {
		t.Errorf("a1 is gone")
	}
	if s.RevokeHandle("ann", Handle(a1)) {
		t.Errorf("ending it twice reports false")
	}
	if !s.RevokeHandle("", Handle(b1)) {
		t.Errorf("an empty user is any: an administrator ends bob's")
	}
	a3, _ := s.CreateMeta("ann", "", "")
	if n := s.RevokeOthers("ann", a3); n != 1 {
		t.Errorf("others: %d", n)
	}
	if _, ok := s.Who(a3); !ok {
		t.Errorf("the kept session survives")
	}
	if _, ok := s.Who(a2); ok {
		t.Errorf("a2 ended")
	}
	if n := s.RevokeAll(); n != 1 {
		t.Errorf("all: %d", n)
	}
	if len(s.List("")) != 0 {
		t.Errorf("nothing is left")
	}
}

func TestExpiredSessionsAreNotListed(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	s := NewSessions(time.Hour, func() time.Time { return now })
	s.CreateMeta("ann", "", "")
	now = now.Add(2 * time.Hour)
	if len(s.List("ann")) != 0 {
		t.Errorf("an expired session is not live")
	}
}

func TestLimiterBlockedDoesNotCount(t *testing.T) {
	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	l := NewLimiter(2, time.Minute, func() time.Time { return now })
	ip := netip.MustParseAddr("10.0.0.9")
	for i := 0; i < 10; i++ {
		if b, _ := l.Blocked(ip); b {
			t.Fatalf("looking is not an attempt: blocked after %d looks", i)
		}
	}
	l.Attempt(ip)
	l.Attempt(ip)
	b, wait := l.Blocked(ip)
	if !b || wait <= 0 || wait > time.Minute {
		t.Errorf("over the cap: %v %v", b, wait)
	}
	now = now.Add(61 * time.Second)
	if b, _ := l.Blocked(ip); b {
		t.Errorf("the window passed")
	}
}

func tokenFile(t *testing.T, tokens ...Token) *Tokens {
	t.Helper()
	var b strings.Builder
	b.WriteString(`{"tokens":[`)
	for i, tk := range tokens {
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(`{"id":"` + tk.ID + `","name":"` + tk.Name + `","user":"` + tk.User + `","scope":"` + tk.Scope + `","hash":"` + tk.Hash + `","created":"2026-01-01T00:00:00Z","expires":"` + tk.Expires + `"}`)
	}
	b.WriteString(`]}`)
	f := filepath.Join(t.TempDir(), "api-tokens.json")
	if err := os.WriteFile(f, []byte(b.String()), 0o640); err != nil {
		t.Fatal(err)
	}
	return &Tokens{File: f, Now: func() time.Time { return time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC) }}
}

func TestTokenLookup(t *testing.T) {
	good := TokenPrefix + strings.Repeat("a", 43)
	other := TokenPrefix + strings.Repeat("b", 43)
	old := TokenPrefix + strings.Repeat("c", 43)
	tk := tokenFile(t,
		Token{ID: "1", Name: "ci", User: "ann", Scope: "read", Hash: HashToken(good), Expires: "2026-12-01T00:00:00Z"},
		Token{ID: "2", Name: "old", User: "ann", Scope: "read", Hash: HashToken(old), Expires: "2026-05-01T00:00:00Z"},
	)
	got, ok, err := tk.Lookup(good)
	if err != nil || !ok || got.ID != "1" {
		t.Fatalf("a live token: %+v %v %v", got, ok, err)
	}
	for name, secret := range map[string]string{"wrong": other, "expired": old, "no prefix": strings.Repeat("a", 47), "empty": "", "long": TokenPrefix + strings.Repeat("a", 200), "the hash itself": HashToken(good)} {
		if _, ok, _ := tk.Lookup(secret); ok {
			t.Errorf("%s must not pass", name)
		}
	}
}

func TestTokenFileProblems(t *testing.T) {
	if list, err := (&Tokens{File: filepath.Join(t.TempDir(), "none.json")}).List(); err != nil || len(list) != 0 {
		t.Errorf("no file is no tokens: %v %v", list, err)
	}
	f := filepath.Join(t.TempDir(), "t.json")
	if err := os.WriteFile(f, []byte("not json"), 0o640); err != nil {
		t.Fatal(err)
	}
	tk := &Tokens{File: f}
	if _, err := tk.List(); err == nil {
		t.Errorf("a damaged file is an error")
	}
	if _, ok, err := tk.Lookup(TokenPrefix + "x"); ok || err == nil {
		t.Errorf("a damaged file never lets a token in, and says why: %v %v", ok, err)
	}
	var nilTokens *Tokens
	if list, err := nilTokens.List(); err != nil || list != nil {
		t.Errorf("a panel without a tokens file: %v %v", list, err)
	}
}

func TestTokenExpired(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	if (Token{Expires: "2026-06-01T00:00:01Z"}).Expired(now) {
		t.Errorf("a second left")
	}
	if !(Token{Expires: "2026-06-01T00:00:00Z"}).Expired(now) {
		t.Errorf("the moment itself is over")
	}
	if !(Token{Expires: "garbage"}).Expired(now) || !(Token{}).Expired(now) {
		t.Errorf("an unreadable time counts as expired")
	}
}

func TestTokenUserNeverHoldsMoreThanTheOwner(t *testing.T) {
	analyst := User{Name: "ann", Role: "analyst"}
	admin := User{Name: "root", Role: "admin"}
	read := TokenUser(Token{Scope: ScopeRead}, analyst)
	if !slices.Equal(read.Effective(), analyst.Effective()) || read.Name != "ann" {
		t.Errorf("a read token keeps the owner's permissions: %v", read.Effective())
	}
	up := TokenUser(Token{Scope: "admin"}, analyst)
	if !slices.Equal(up.Effective(), analyst.Effective()) {
		t.Errorf("a token of a higher role gets only what the owner has: %v", up.Effective())
	}
	if up.Has(PermUsersManage) || up.Has(PermSettingsEdit) {
		t.Errorf("no escalation")
	}
	down := TokenUser(Token{Scope: "viewer"}, admin)
	if !slices.Equal(down.Effective(), []string{PermView}) {
		t.Errorf("a viewer token of an admin is a viewer: %v", down.Effective())
	}
	if len(TokenUser(Token{Scope: "nonsense"}, admin).Effective()) != 0 {
		t.Errorf("an unknown scope holds nothing")
	}
	// the owner losing a permission takes it from the token at once
	reduced := TokenUser(Token{Scope: "operator"}, User{Name: "o", Role: "custom", Perms: []string{PermView}})
	if !slices.Equal(reduced.Effective(), []string{PermView}) {
		t.Errorf("the intersection follows the owner: %v", reduced.Effective())
	}
}
