package ctl

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// The messages of dpistack-ctl are Russian, two bytes a letter: a cut at a
// fixed byte count must not leave half a letter at the end.
func TestFirstLineDoesNotCutALetterInHalf(t *testing.T) {
	long := "dpistack-ctl: " + strings.Repeat("я", 150) + "\nвторая строка"
	got := firstLine(long)
	if !utf8.ValidString(got) {
		t.Fatalf("firstLine returned invalid UTF-8: %q", got)
	}
	if len(got) > 200 || len(got) < 198 {
		t.Errorf("firstLine is %d bytes, want 198 or 200", len(got))
	}
	if strings.Contains(got, "\n") || strings.HasPrefix(got, "dpistack-ctl:") {
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
