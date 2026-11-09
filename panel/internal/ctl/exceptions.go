package ctl

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Exception is one entry of threshold.config as `exceptions list --json`
// prints it (tech.md 18.40). DaysLeft is nil for an entry that never
// expires.
type Exception struct {
	ID       string `json:"id"`
	Kind     string `json:"kind"`
	SID      int    `json:"sid"`
	Track    string `json:"track"`
	IP       string `json:"ip"`
	Count    int    `json:"count"`
	Seconds  int    `json:"seconds"`
	Added    string `json:"added"`
	Expires  string `json:"expires"`
	DaysLeft *int   `json:"days_left"`
	Expired  bool   `json:"expired"`
	By       string `json:"by"`
	Note     string `json:"note"`
}

// ExceptionList is the whole answer of `exceptions list --json`.
type ExceptionList struct {
	DefaultDays int         `json:"default_days"`
	Today       string      `json:"today"`
	Entries     []Exception `json:"entries"`
}

// ExceptionAdd is what the screen sends. Empty strings and zero values mean
// "not given": dpistack applies its own default (EXCEPTIONS_DEFAULT_DAYS)
// and refuses a combination that makes no sense, so the CLI and the screen
// cannot differ.
type ExceptionAdd struct {
	Kind    string
	SID     string
	Track   string
	IP      string
	Count   string
	Seconds string
	Days    string
	Never   bool
	Note    string
	By      string
}

// Exceptions runs `exceptions list --json`.
func (r *Runner) Exceptions(ctx context.Context) (ExceptionList, error) {
	var out ExceptionList
	raw, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "exceptions", "list", "--json")
	if err != nil {
		return out, err
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return out, fmt.Errorf("ctl: exceptions list: %w", err)
	}
	if out.Entries == nil {
		out.Entries = []Exception{}
	}
	return out, nil
}

// args builds the argument list of `exceptions add`.
func (a ExceptionAdd) args() []string {
	args := []string{"exceptions", "add", a.Kind, a.SID}
	for _, o := range []struct{ flag, value string }{
		{"--track", a.Track}, {"--ip", a.IP}, {"--count", a.Count}, {"--seconds", a.Seconds},
		{"--days", a.Days}, {"--note", a.Note}, {"--by", a.By},
	} {
		if o.value != "" {
			args = append(args, o.flag, o.value)
		}
	}
	if a.Never {
		args = append(args, "--never")
	}
	return args
}

// ExceptionAdd runs `exceptions add` and returns the id of the new entry,
// the last line dpistack prints.
func (r *Runner) ExceptionAdd(ctx context.Context, a ExceptionAdd) (string, error) {
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, a.args()...)
	if err != nil {
		return "", err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	return strings.TrimSpace(lines[len(lines)-1]), nil
}

// ExceptionRemove runs `exceptions remove <id>`.
func (r *Runner) ExceptionRemove(ctx context.Context, id string) error {
	_, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "exceptions", "remove", id)
	return err
}

// FormatDays is the text of a number the screen sends as JSON.
func FormatDays(n int) string {
	if n <= 0 {
		return ""
	}
	return strconv.Itoa(n)
}
