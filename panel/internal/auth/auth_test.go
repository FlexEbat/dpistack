package auth

import (
	"errors"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Both hashes come from the argon2 CLI the installer uses:
//
//	printf 'correct horse' | argon2 saltsaltsaltsalt -id -t 3 -m 14 -p 4 -l 32 -e
const (
	hashOK    = "$argon2id$v=19$m=16384,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$06P4n5MT+1p4xkEaN81bac/LFLj2y/TdZ8HFiBx7mOc"
	hashHeavy = "$argon2id$v=19$m=65536,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$LeZbD3UAKvUcACx9il4XPtXtFiDX3/ScRE4eQjOYNyM"
)

func TestVerifyCLIHash(t *testing.T) {
	ok, err := Verify(hashOK, "correct horse")
	if err != nil || !ok {
		t.Fatalf("right password: ok=%v err=%v", ok, err)
	}
	ok, err = Verify(hashOK, "wrong")
	if err != nil || ok {
		t.Fatalf("wrong password: ok=%v err=%v", ok, err)
	}
}

func TestVerifyRejectsBadHashes(t *testing.T) {
	if _, err := Verify(hashHeavy, "correct horse"); !errors.Is(err, ErrHashTooHeavy) {
		t.Errorf("heavy hash: %v", err)
	}
	for _, bad := range []string{"", "plain", "$argon2i$v=19$m=16,t=3,p=4$c2FsdHNhbHRzYWx0c2FsdA$AAAAAAAAAAAAAAAAAAAAAA", "$argon2id$v=19$m=x$a$b"} {
		if _, err := Verify(bad, "x"); !errors.Is(err, ErrHashFormat) {
			t.Errorf("%q: %v", bad, err)
		}
	}
}

func TestVerifyFile(t *testing.T) {
	dir := t.TempDir()
	if _, err := VerifyFile(filepath.Join(dir, "missing"), "x"); !errors.Is(err, ErrNoPassword) {
		t.Errorf("missing file: %v", err)
	}
	path := filepath.Join(dir, "panel.auth")
	if err := os.WriteFile(path, []byte(hashOK+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if ok, err := VerifyFile(path, "correct horse"); err != nil || !ok {
		t.Errorf("ok=%v err=%v", ok, err)
	}
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

// Slice 16 criterion 2: the sixth attempt inside 5 minutes is refused.
func TestLimiterSixthAttempt(t *testing.T) {
	c := &clock{t: time.Unix(1000, 0)}
	l := NewLimiter(5, 5*time.Minute, c.now)
	ip := netip.MustParseAddr("192.0.2.1")
	for i := 1; i <= 5; i++ {
		if ok, _ := l.Attempt(ip); !ok {
			t.Fatalf("attempt %d refused", i)
		}
		c.t = c.t.Add(10 * time.Second)
	}
	ok, wait := l.Attempt(ip)
	if ok || wait <= 0 {
		t.Fatalf("sixth attempt: ok=%v wait=%v", ok, wait)
	}
	if ok, _ := l.Attempt(netip.MustParseAddr("192.0.2.2")); !ok {
		t.Error("another address must not share the cap")
	}
	c.t = c.t.Add(5 * time.Minute)
	if ok, _ := l.Attempt(ip); !ok {
		t.Error("the window must expire")
	}
}

func TestLimiterReset(t *testing.T) {
	c := &clock{t: time.Unix(1000, 0)}
	l := NewLimiter(2, time.Minute, c.now)
	ip := netip.MustParseAddr("192.0.2.1")
	l.Attempt(ip)
	l.Attempt(ip)
	l.Reset(ip)
	if ok, _ := l.Attempt(ip); !ok {
		t.Error("reset must clear the attempts")
	}
}

func TestSessionsExpireAfterTTL(t *testing.T) {
	c := &clock{t: time.Unix(1000, 0)}
	s := NewSessions(12*time.Hour, c.now)
	id, csrf := s.Create()
	if got, ok := s.Get(id); !ok || got != csrf {
		t.Fatalf("fresh session: %q %v", got, ok)
	}
	c.t = c.t.Add(12*time.Hour - time.Second)
	if _, ok := s.Get(id); !ok {
		t.Error("session must live 12 hours")
	}
	c.t = c.t.Add(time.Second)
	if _, ok := s.Get(id); ok {
		t.Error("session must expire after 12 hours")
	}
	id2, _ := s.Create()
	s.Delete(id2)
	if _, ok := s.Get(id2); ok {
		t.Error("deleted session still valid")
	}
}

func TestSessionsAreBounded(t *testing.T) {
	c := &clock{t: time.Unix(1000, 0)}
	s := NewSessions(time.Hour, c.now)
	first, _ := s.Create()
	for i := 0; i < maxSessions; i++ {
		c.t = c.t.Add(time.Second)
		s.Create()
	}
	if _, ok := s.Get(first); ok {
		t.Error("oldest session must be evicted at the cap")
	}
}

// Slice 16 criterion 4.
func TestPolicy(t *testing.T) {
	tests := []struct {
		name, mode, cidr, remote, xff string
		want                          bool
	}{
		{"localhost loopback", "localhost", "", "127.0.0.1:5000", "", true},
		{"localhost ipv6 loopback", "localhost", "", "[::1]:5000", "", true},
		{"localhost from lan", "localhost", "", "192.168.1.5:5000", "", false},
		{"lan inside", "lan", "192.168.1.0/24", "192.168.1.5:5000", "", true},
		{"lan outside", "lan", "192.168.1.0/24", "10.0.0.5:5000", "", false},
		{"lan loopback is outside the cidr", "lan", "192.168.1.0/24", "127.0.0.1:5000", "", false},
		{"xff from a stranger is ignored", "lan", "192.168.1.0/24", "10.0.0.5:5000", "192.168.1.9", false},
		{"xff cannot hide a stranger inside lan", "lan", "192.168.1.0/24", "192.168.1.5:5000", "10.0.0.1", true},
		{"xff from loopback is used", "nginx", "192.168.1.0/24", "127.0.0.1:5000", "192.168.1.9", true},
		{"xff from loopback outside cidr", "nginx", "192.168.1.0/24", "127.0.0.1:5000", "10.0.0.1", false},
		{"xff last entry wins", "nginx", "192.168.1.0/24", "127.0.0.1:5000", "192.168.1.9, 10.0.0.1", false},
		{"nginx without cidr", "nginx", "", "127.0.0.1:5000", "203.0.113.7", true},
		{"nginx peer must be loopback", "nginx", "", "203.0.113.7:5000", "", false},
		{"localhost with forwarded stranger", "localhost", "", "127.0.0.1:5000", "203.0.113.7", false},
		{"v4-mapped peer", "lan", "192.168.1.0/24", "[::ffff:192.168.1.5]:5000", "", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p, err := NewPolicy(tc.mode, tc.cidr)
			if err != nil {
				t.Fatal(err)
			}
			var xff []string
			if tc.xff != "" {
				xff = []string{tc.xff}
			}
			peer, client, err := p.ClientIP(tc.remote, xff)
			if err != nil {
				t.Fatal(err)
			}
			if got := p.Allowed(peer, client); got != tc.want {
				t.Errorf("Allowed = %v, want %v (peer %v client %v)", got, tc.want, peer, client)
			}
		})
	}
}

func TestPolicyBadForwardedHeaderFailsClosed(t *testing.T) {
	p, _ := NewPolicy("nginx", "")
	if _, _, err := p.ClientIP("127.0.0.1:5000", []string{"not-an-ip"}); err == nil {
		t.Error("a malformed header from the proxy must be an error")
	}
}

func TestNewPolicyValidation(t *testing.T) {
	for _, tc := range [][2]string{{"lan", ""}, {"lan", "nonsense"}, {"open", ""}} {
		if _, err := NewPolicy(tc[0], tc[1]); err == nil {
			t.Errorf("NewPolicy(%q, %q) must fail", tc[0], tc[1])
		}
	}
}
