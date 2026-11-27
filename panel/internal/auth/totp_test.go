package auth

import (
	"strings"
	"testing"
	"time"
)

// The secret and the codes of RFC 6238 appendix B (SHA-1), as 6 digits.
const rfcSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

func guardAt(unix int64) *TOTPGuard {
	return &TOTPGuard{Now: func() time.Time { return time.Unix(unix, 0) }}
}

func TestTOTPMatchesRFC6238Vectors(t *testing.T) {
	cases := []struct {
		at   int64
		code string
	}{
		{59, "287082"},
		{1111111109, "081804"},
		{1111111111, "050471"},
		{1234567890, "005924"},
		{2000000000, "279037"},
		{20000000000, "353130"},
	}
	for _, c := range cases {
		if !guardAt(c.at).Check("u", rfcSecret, c.code) {
			t.Errorf("at %d the code %s must be good", c.at, c.code)
		}
	}
}

func TestTOTPRefusesWrongAndMalformedCodes(t *testing.T) {
	g := guardAt(59)
	for _, code := range []string{"", "000000", "28708", "2870822", "abcdef", "287 08"} {
		if g.Check("u", rfcSecret, code) {
			t.Errorf("%q must not be good", code)
		}
	}
	// Spaces and dashes people type are ignored.
	if !g.Check("u", rfcSecret, "287 082") {
		t.Error("a code typed in two groups must be good")
	}
}

func TestTOTPAcceptsOneStepEitherSideAndNoMore(t *testing.T) {
	// 287082 is the code of the step at 59 s (step 1).
	if !guardAt(59+TOTPPeriod).Check("u", rfcSecret, "287082") {
		t.Error("the previous step must still be good")
	}
	if !guardAt(59-TOTPPeriod+1).Check("u", rfcSecret, "287082") && !guardAt(30).Check("u", rfcSecret, "287082") {
		t.Error("a clock a little behind must still work")
	}
	if guardAt(59+3*TOTPPeriod).Check("u", rfcSecret, "287082") {
		t.Error("a code from three steps ago must not be good")
	}
}

func TestTOTPCodeIsGoodOnceAndOlderOnesNever(t *testing.T) {
	now := int64(1111111109)
	g := &TOTPGuard{Now: func() time.Time { return time.Unix(now, 0) }}
	if !g.Check("u", rfcSecret, "081804") {
		t.Fatal("the first use must be good")
	}
	if g.Check("u", rfcSecret, "081804") {
		t.Fatal("the same code twice must not be good")
	}
	// The next step's code is fine, and then the old one is behind it.
	now += TOTPPeriod
	if !g.Check("u", rfcSecret, "050471") {
		t.Fatal("the next step must be good")
	}
	now -= TOTPPeriod
	if g.Check("u", rfcSecret, "081804") {
		t.Fatal("an older step after a newer one must not be good")
	}
	// Another account is not affected.
	if !g.Check("other", rfcSecret, "081804") {
		t.Fatal("what is remembered is per account")
	}
	g.Forget("u")
	if !g.Check("u", rfcSecret, "050471") {
		t.Fatal("after Forget the account starts again")
	}
}

func TestTOTPBadSecretIsNotGood(t *testing.T) {
	if guardAt(59).Check("u", "not base32 !!", "287082") {
		t.Fatal("a secret that is not Base32 must not accept anything")
	}
}

func TestRecoveryCodesAreUniqueFormattedAndMatchOnce(t *testing.T) {
	plain, hashes, err := NewRecoveryCodes()
	if err != nil {
		t.Fatal(err)
	}
	if len(plain) != RecoveryCount || len(hashes) != RecoveryCount {
		t.Fatalf("want %d codes, got %d and %d", RecoveryCount, len(plain), len(hashes))
	}
	seen := map[string]bool{}
	for i, c := range plain {
		if len(c) != 11 || c[5] != '-' {
			t.Errorf("code %q is not xxxxx-xxxxx", c)
		}
		if strings.ContainsAny(c, "01ilo") {
			t.Errorf("code %q has a character that is easy to misread", c)
		}
		if seen[c] {
			t.Errorf("code %q is twice", c)
		}
		seen[c] = true
		if hashes[i] != HashRecovery(c) {
			t.Errorf("the hash of %q is not the stored one", c)
		}
		if strings.Contains(hashes[i], strings.ReplaceAll(c, "-", "")) {
			t.Errorf("the hash of %q contains the code", c)
		}
	}
	tt := TOTP{Secret: rfcSecret, Recovery: hashes}
	h, ok := tt.MatchRecovery(strings.ToUpper(plain[3]))
	if !ok || h != hashes[3] {
		t.Fatalf("an upper case code with its dash must match its own hash, got %q %v", h, ok)
	}
	if _, ok := tt.MatchRecovery(strings.ReplaceAll(plain[4], "-", " ")); !ok {
		t.Error("a code typed with a space must match")
	}
	for _, bad := range []string{"", "aaaaa-aaaaa", plain[0][:5], plain[0] + "x"} {
		if _, ok := tt.MatchRecovery(bad); ok {
			t.Errorf("%q must not match", bad)
		}
	}
}

func TestTicketsAreBoundToTheAddressExpireAndAllowFiveTries(t *testing.T) {
	now := time.Unix(1000, 0)
	tk := &Tickets{Now: func() time.Time { return now }}
	id := tk.Create("ann", "10.0.0.1")
	if u, ok := tk.Peek(id, "10.0.0.1"); !ok || u != "ann" {
		t.Fatalf("the ticket must give its user, got %q %v", u, ok)
	}
	if _, ok := tk.Peek(id, "10.0.0.2"); ok {
		t.Fatal("another address must not use the ticket")
	}
	if _, ok := tk.Peek("nope", "10.0.0.1"); ok {
		t.Fatal("an unknown ticket is not valid")
	}
	for i := 0; i < TicketTries-1; i++ {
		tk.Fail(id)
		if _, ok := tk.Peek(id, "10.0.0.1"); !ok {
			t.Fatalf("the ticket must live after %d wrong codes", i+1)
		}
	}
	tk.Fail(id)
	if _, ok := tk.Peek(id, "10.0.0.1"); ok {
		t.Fatal("the ticket must be gone after five wrong codes")
	}

	id = tk.Create("ann", "10.0.0.1")
	now = now.Add(TicketTTL + time.Second)
	if _, ok := tk.Peek(id, "10.0.0.1"); ok {
		t.Fatal("the ticket must end after its time")
	}

	id = tk.Create("ann", "10.0.0.1")
	tk.Done(id)
	if _, ok := tk.Peek(id, "10.0.0.1"); ok {
		t.Fatal("a used ticket is gone")
	}
}

func TestTicketTableDoesNotGrowWithoutEnd(t *testing.T) {
	tk := &Tickets{}
	for i := 0; i < maxTickets+50; i++ {
		tk.Create("ann", "10.0.0.1")
	}
	tk.mu.Lock()
	n := len(tk.m)
	tk.mu.Unlock()
	if n > maxTickets {
		t.Fatalf("the table holds %d tickets, the cap is %d", n, maxTickets)
	}
}
