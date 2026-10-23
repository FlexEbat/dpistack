package ctl

import (
	"context"
	"strings"
	"testing"
	"unicode/utf8"
)

// The messages of dpistack are Russian, two bytes a letter: a cut at a
// fixed byte count must not leave half a letter at the end.
func TestFirstLineDoesNotCutALetterInHalf(t *testing.T) {
	long := "dpistack: " + strings.Repeat("я", 150) + "\nвторая строка"
	got := firstLine(long)
	if !utf8.ValidString(got) {
		t.Fatalf("firstLine returned invalid UTF-8: %q", got)
	}
	if len(got) > 200 || len(got) < 198 {
		t.Errorf("firstLine is %d bytes, want 198 or 200", len(got))
	}
	if strings.Contains(got, "\n") || strings.HasPrefix(got, "dpistack:") {
		t.Errorf("firstLine = %q", got)
	}
}

func TestCutUTF8(t *testing.T) {
	for _, tc := range []struct {
		in   string
		n    int
		want string
	}{
		{"abc", 10, "abc"},
		{"abcdef", 3, "abc"},
		{"яя", 3, "я"},
		{"яя", 4, "яя"},
		{"日本語", 4, "日"},
		{"я", 1, ""},
	} {
		if got := cutUTF8(tc.in, tc.n); got != tc.want {
			t.Errorf("cutUTF8(%q, %d) = %q, want %q", tc.in, tc.n, got, tc.want)
		}
	}
}

// The panel in a container reaches dpistack on the host through the prefix,
// and says who is calling.
func TestPrefixRunsOnTheHostAndNamesTheCaller(t *testing.T) {
	r := &Runner{Path: "/usr/local/sbin/dpistack", Prefix: []string{"nsenter", "-t", "1", "-m", "--"}}
	cmd := r.command(context.Background(), "status", "--json")
	want := []string{"nsenter", "-t", "1", "-m", "--", "env", "DPISTACK_CALLER=panel", "/usr/local/sbin/dpistack", "status", "--json"}
	got := append([]string{cmd.Path}, cmd.Args[1:]...)
	if cmd.Args[0] != "nsenter" || strings.Join(cmd.Args, " ") != strings.Join(want, " ") {
		t.Errorf("argv %q, want %q (path %s)", cmd.Args, want, got[0])
	}
	// the prefix wins over sudo
	r.Sudo = true
	if c := r.command(context.Background(), "x"); c.Args[0] != "nsenter" {
		t.Errorf("sudo used with a prefix: %q", c.Args)
	}
}
