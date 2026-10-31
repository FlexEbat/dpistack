package auth

import (
	"crypto/rand"
	"encoding/base64"
	"net/netip"
	"sync"
	"time"
)

// maxSessions bounds memory.
const maxSessions = 64

type session struct {
	csrf    string
	user    string
	expires time.Time
}

// Sessions keeps logged-in sessions in memory; a panel restart logs the
// administrator out, which is the intended cost of having no database.
type Sessions struct {
	mu  sync.Mutex
	m   map[string]session
	ttl time.Duration
	now func() time.Time
}

// NewSessions returns a store whose sessions live ttl from creation.
func NewSessions(ttl time.Duration, now func() time.Time) *Sessions {
	return &Sessions{m: map[string]session{}, ttl: ttl, now: now}
}

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("auth: no randomness: " + err.Error())
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// Create starts a session of the user admin (the one-password panel).
func (s *Sessions) Create() (id, csrf string) {
	return s.CreateFor("admin")
}

// CreateFor starts a session of a user and returns its id and its CSRF token.
func (s *Sessions) CreateFor(user string) (id, csrf string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, v := range s.m {
		if !now.Before(v.expires) {
			delete(s.m, k)
		}
	}
	for len(s.m) >= maxSessions {
		var oldest string
		for k, v := range s.m {
			if oldest == "" || v.expires.Before(s.m[oldest].expires) {
				oldest = k
			}
		}
		delete(s.m, oldest)
	}
	id, csrf = randomToken(), randomToken()
	s.m[id] = session{csrf: csrf, user: user, expires: now.Add(s.ttl)}
	return id, csrf
}

// Get returns the CSRF token of a live session.
func (s *Sessions) Get(id string) (csrf string, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, found := s.m[id]
	if !found {
		return "", false
	}
	if !s.now().Before(v.expires) {
		delete(s.m, id)
		return "", false
	}
	return v.csrf, true
}

// Who returns the user of a live session.
func (s *Sessions) Who(id string) (user string, ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, found := s.m[id]
	if !found || !s.now().Before(v.expires) {
		return "", false
	}
	return v.user, true
}

// DeleteUser ends every session of a user (a changed role or password).
func (s *Sessions) DeleteUser(user string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, v := range s.m {
		if v.user == user {
			delete(s.m, k)
		}
	}
}

// Delete ends a session.
func (s *Sessions) Delete(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, id)
}

// Limiter caps login attempts per client address inside a sliding window.
type Limiter struct {
	mu     sync.Mutex
	tries  map[netip.Addr][]time.Time
	max    int
	window time.Duration
	now    func() time.Time
}

// NewLimiter allows max attempts per window for one address.
func NewLimiter(max int, window time.Duration, now func() time.Time) *Limiter {
	return &Limiter{tries: map[netip.Addr][]time.Time{}, max: max, window: window, now: now}
}

// Attempt records an attempt and reports whether it may proceed. The attempt
// is counted before the password is checked, so a burst of parallel guesses
// cannot slip past the cap. When it may not, retryAfter says how long until
// the oldest recorded attempt leaves the window.
func (l *Limiter) Attempt(ip netip.Addr) (ok bool, retryAfter time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if len(l.tries) > 1024 {
		for k, v := range l.tries {
			if now.Sub(v[len(v)-1]) >= l.window {
				delete(l.tries, k)
			}
		}
	}
	kept := l.tries[ip][:0]
	for _, t := range l.tries[ip] {
		if now.Sub(t) < l.window {
			kept = append(kept, t)
		}
	}
	if len(kept) >= l.max {
		l.tries[ip] = kept
		return false, kept[0].Add(l.window).Sub(now)
	}
	l.tries[ip] = append(kept, now)
	return true, 0
}

// Reset forgets the attempts of an address after a successful login.
func (l *Limiter) Reset(ip netip.Addr) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.tries, ip)
}
