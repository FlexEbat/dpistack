package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
	"sync"
	"time"

	"github.com/pquerna/otp"
	"github.com/pquerna/otp/hotp"
)

// TOTP is the second factor of an account (RFC 6238: SHA-1, 6 digits, 30
// seconds, what every authenticator app does). It lives in users.json next to
// the hash. Secret is Base32. Recovery holds the SHA-256 of each recovery code
// that has not been used; a used one is removed.
type TOTP struct {
	Secret   string   `json:"secret"`
	Enabled  string   `json:"enabled,omitempty"`
	Recovery []string `json:"recovery,omitempty"`
}

const (
	// TOTPPeriod is the length of one code in seconds.
	TOTPPeriod = 30
	// totpSkew is how many periods either side of now are accepted: a clock
	// that is a little off still works, a code from two minutes ago does not.
	totpSkew = 1
	// RecoveryCount is how many recovery codes an account gets.
	RecoveryCount = 10
	// recoveryAlphabet has no 0, 1, i, l, o: a code is read from paper.
	recoveryAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"
	recoveryLen      = 10
)

// TOTPGuard checks codes and remembers, for each account, the newest time
// step that was accepted: a code is good once, and an older step never again,
// so a code seen over a shoulder or in a log cannot be replayed. The memory is
// the panel's own; a restart forgets it, which leaves the one 90 second
// window of the last code open (users.json is not written at every sign-in).
type TOTPGuard struct {
	Now func() time.Time

	mu   sync.Mutex
	last map[string]int64
}

func (g *TOTPGuard) now() time.Time {
	if g.Now != nil {
		return g.Now()
	}
	return time.Now()
}

// NormalizeCode drops the spaces and dashes people type into a code.
func NormalizeCode(code string) string {
	return strings.Map(func(r rune) rune {
		if r == ' ' || r == '-' || r == '\t' {
			return -1
		}
		return r
	}, strings.TrimSpace(code))
}

// step returns the time step that code is the code of, or -1. Every step in
// the window is computed and compared, so the time does not tell which one
// matched.
func (g *TOTPGuard) step(secret, code string) int64 {
	code = NormalizeCode(code)
	if len(code) != 6 {
		return -1
	}
	now := g.now().Unix() / TOTPPeriod
	good := int64(-1)
	for c := now - totpSkew; c <= now+totpSkew; c++ {
		want, err := hotp.GenerateCodeCustom(secret, uint64(c), hotp.ValidateOpts{Digits: otp.DigitsSix, Algorithm: otp.AlgorithmSHA1})
		if err != nil {
			return -1
		}
		if subtle.ConstantTimeCompare([]byte(want), []byte(code)) == 1 {
			good = c
		}
	}
	return good
}

// Valid says whether code is a current code of secret, and remembers nothing:
// it is for the moment a person sets the second factor up, when the same code
// must not be spent before the first real sign-in.
func (g *TOTPGuard) Valid(secret, code string) bool {
	return g.step(secret, code) >= 0
}

// Check says whether code is the current code of secret for user, and spends
// it: the same code, or an older one, is not good again.
func (g *TOTPGuard) Check(user, secret, code string) bool {
	good := g.step(secret, code)
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.last == nil {
		g.last = map[string]int64{}
	}
	if good < 0 || good <= g.last[user] {
		return false
	}
	g.last[user] = good
	return true
}

// Forget drops what is remembered of an account (it was removed or its
// second factor was reset).
func (g *TOTPGuard) Forget(user string) {
	g.mu.Lock()
	delete(g.last, user)
	g.mu.Unlock()
}

// NewRecoveryCodes makes RecoveryCount codes: what the person is shown once
// (xxxxx-xxxxx) and the hashes that are stored.
func NewRecoveryCodes() (plain, hashes []string, err error) {
	for i := 0; i < RecoveryCount; i++ {
		raw := make([]byte, recoveryLen)
		if _, err = rand.Read(raw); err != nil {
			return nil, nil, err
		}
		b := make([]byte, recoveryLen)
		for j, v := range raw {
			// 256 is not a multiple of 31, but 8 bits over 31 symbols leaves a
			// bias under 3% on a 50 bit code that is checked only against
			// stored hashes and is good once: not worth a rejection loop.
			b[j] = recoveryAlphabet[int(v)%len(recoveryAlphabet)]
		}
		code := string(b[:5]) + "-" + string(b[5:])
		plain = append(plain, code)
		hashes = append(hashes, HashRecovery(code))
	}
	return plain, hashes, nil
}

// HashRecovery is the stored form of a recovery code: SHA-256 of the code
// without dashes or spaces, in lower case. A code is long and random, so a
// plain hash is enough (a slow one would only slow down the sign-in).
func HashRecovery(code string) string {
	sum := sha256.Sum256([]byte(strings.ToLower(NormalizeCode(code))))
	return hex.EncodeToString(sum[:])
}

// MatchRecovery returns the stored hash that code matches, and whether it
// matched. It looks at every stored hash, so the time does not tell which.
func (t TOTP) MatchRecovery(code string) (string, bool) {
	code = NormalizeCode(code)
	if len(code) != recoveryLen {
		return "", false
	}
	h := HashRecovery(code)
	found := ""
	for _, stored := range t.Recovery {
		if subtle.ConstantTimeCompare([]byte(stored), []byte(h)) == 1 {
			found = stored
		}
	}
	return found, found != ""
}

// Tickets are the short step between the right password and the second
// factor: the password was good, no session exists yet. A ticket is bound to
// the address it was given to, ends after TicketTTL, allows TicketTries wrong
// codes, and is gone after one good one.
type Tickets struct {
	Now func() time.Time

	mu sync.Mutex
	m  map[string]ticket
}

type ticket struct {
	user, ip string
	expires  time.Time
	tries    int
}

const (
	TicketTTL   = 5 * time.Minute
	TicketTries = 5
	maxTickets  = 1000
)

func (t *Tickets) now() time.Time {
	if t.Now != nil {
		return t.Now()
	}
	return time.Now()
}

// Create returns a new ticket for user at ip.
func (t *Tickets) Create(user, ip string) string {
	id := randomToken()
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.m == nil {
		t.m = map[string]ticket{}
	}
	now := t.now()
	for k, v := range t.m {
		if now.After(v.expires) {
			delete(t.m, k)
		}
	}
	// A flood of passwords that were right cannot grow the table without end.
	if len(t.m) >= maxTickets {
		for k := range t.m {
			delete(t.m, k)
			break
		}
	}
	t.m[id] = ticket{user: user, ip: ip, expires: now.Add(TicketTTL)}
	return id
}

// Peek returns the user of a valid ticket for ip. A ticket that does not
// exist, ended, or was given to another address is not valid.
func (t *Tickets) Peek(id, ip string) (user string, ok bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	v, found := t.m[id]
	if !found {
		return "", false
	}
	if t.now().After(v.expires) {
		delete(t.m, id)
		return "", false
	}
	if subtle.ConstantTimeCompare([]byte(v.ip), []byte(ip)) != 1 {
		return "", false
	}
	return v.user, true
}

// Fail counts a wrong code; the ticket is gone after TicketTries of them.
func (t *Tickets) Fail(id string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	v, found := t.m[id]
	if !found {
		return
	}
	v.tries++
	if v.tries >= TicketTries {
		delete(t.m, id)
		return
	}
	t.m[id] = v
}

// Done removes a ticket that was used.
func (t *Tickets) Done(id string) {
	t.mu.Lock()
	delete(t.m, id)
	t.mu.Unlock()
}
