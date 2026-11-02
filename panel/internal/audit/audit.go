// Package audit keeps the audit log of the panel (tech.md slice 35): one JSON
// object per line in audit.jsonl, appended by the panel and by `dpistack` when
// root runs a verb by hand, rotated by size. A line never holds a password, a
// token or a hash: callers pass names and flags, never values.
package audit

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Entry is one line of the log.
type Entry struct {
	TS     string `json:"ts"`
	User   string `json:"user"`
	IP     string `json:"ip,omitempty"`
	Action string `json:"action"`
	Target string `json:"target,omitempty"`
	Result string `json:"result"`
	Detail string `json:"detail,omitempty"`
}

// Results of an action.
const (
	ResultOK     = "ok"
	ResultDenied = "denied"
	ResultError  = "error"
)

const (
	// DefaultMaxBytes and DefaultKeep: rotated at 10 MB, 5 files in all.
	DefaultMaxBytes = 10 << 20
	DefaultKeep     = 5
	maxLine         = 2048
	// MaxRead bounds one read of the log.
	MaxRead = 5000
)

// Log is the audit log. The zero value does nothing, so a panel started
// without -audit-file keeps working.
type Log struct {
	Path     string
	MaxBytes int64
	Keep     int
	Now      func() time.Time

	mu sync.Mutex
}

func (l *Log) maxBytes() int64 {
	if l.MaxBytes > 0 {
		return l.MaxBytes
	}
	return DefaultMaxBytes
}

func (l *Log) keep() int {
	if l.Keep > 1 {
		return l.Keep
	}
	return DefaultKeep
}

func clean(s string) string {
	s = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, s)
	if len(s) > 256 {
		s = s[:256]
	}
	return s
}

// Write appends an entry. A failure to write is returned, never fatal: the
// panel logs it and goes on.
func (l *Log) Write(e Entry) error {
	if l == nil || l.Path == "" {
		return nil
	}
	now := time.Now
	if l.Now != nil {
		now = l.Now
	}
	if e.TS == "" {
		e.TS = now().UTC().Format(time.RFC3339)
	}
	e.User, e.IP, e.Action = clean(e.User), clean(e.IP), clean(e.Action)
	e.Target, e.Detail, e.Result = clean(e.Target), clean(e.Detail), clean(e.Result)
	if e.Result == "" {
		e.Result = ResultOK
	}
	line, err := json.Marshal(e)
	if err != nil {
		return err
	}
	if len(line) > maxLine {
		return errors.New("audit: entry too long")
	}
	line = append(line, '\n')

	l.mu.Lock()
	defer l.mu.Unlock()
	if err := l.rotate(); err != nil {
		return err
	}
	f, err := os.OpenFile(l.Path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o660)
	if err != nil {
		return err
	}
	_, werr := f.Write(line)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	return werr
}

// rotate moves audit.jsonl to .1 when it is full: .1 to .2 and so on, the
// oldest file goes.
func (l *Log) rotate() error {
	st, err := os.Stat(l.Path)
	if err != nil || st.Size() < l.maxBytes() {
		return nil
	}
	keep := l.keep()
	_ = os.Remove(l.Path + "." + strconv.Itoa(keep-1))
	for i := keep - 2; i >= 1; i-- {
		from, to := l.Path+"."+strconv.Itoa(i), l.Path+"."+strconv.Itoa(i+1)
		if err := os.Rename(from, to); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	return os.Rename(l.Path, l.Path+".1")
}

// Filter selects entries; the zero value selects everything.
type Filter struct {
	User   string // exact
	Action string // substring
	Result string // exact
	Since  time.Time
	Until  time.Time
	Limit  int
}

func (f Filter) match(e Entry) bool {
	if f.User != "" && e.User != f.User {
		return false
	}
	if f.Result != "" && e.Result != f.Result {
		return false
	}
	if f.Action != "" && !strings.Contains(strings.ToLower(e.Action+" "+e.Target), strings.ToLower(f.Action)) {
		return false
	}
	if !f.Since.IsZero() || !f.Until.IsZero() {
		ts, err := time.Parse(time.RFC3339, e.TS)
		if err != nil {
			return false
		}
		if !f.Since.IsZero() && ts.Before(f.Since) {
			return false
		}
		if !f.Until.IsZero() && ts.After(f.Until) {
			return false
		}
	}
	return true
}

// Read returns the matching entries, the newest first, from the current file
// and the rotated ones. A damaged line is skipped.
func (l *Log) Read(f Filter) ([]Entry, error) {
	if l == nil || l.Path == "" {
		return nil, nil
	}
	limit := f.Limit
	if limit <= 0 || limit > MaxRead {
		limit = 200
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []Entry
	files := []string{l.Path}
	for i := 1; i < l.keep(); i++ {
		files = append(files, l.Path+"."+strconv.Itoa(i))
	}
	for _, name := range files {
		part, err := readFile(name)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for i := len(part) - 1; i >= 0; i-- {
			if f.match(part[i]) {
				out = append(out, part[i])
				if len(out) >= limit {
					return out, nil
				}
			}
		}
	}
	return out, nil
}

func readFile(name string) ([]Entry, error) {
	fh, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer fh.Close()
	var out []Entry
	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	for sc.Scan() {
		var e Entry
		if json.Unmarshal(sc.Bytes(), &e) == nil && e.TS != "" {
			out = append(out, e)
		}
	}
	return out, sc.Err()
}

// WriteCSV writes entries as CSV with a header, for the export.
func WriteCSV(w io.Writer, list []Entry) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{"ts", "user", "ip", "action", "target", "result", "detail"}); err != nil {
		return err
	}
	for _, e := range list {
		row := []string{e.TS, e.User, e.IP, e.Action, e.Target, e.Result, e.Detail}
		for i, c := range row {
			// A cell that starts like a formula would run in a spreadsheet.
			if strings.HasPrefix(c, "=") || strings.HasPrefix(c, "+") || strings.HasPrefix(c, "-") || strings.HasPrefix(c, "@") {
				row[i] = "'" + c
			}
		}
		if err := cw.Write(row); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// String is for logs of the panel itself.
func (e Entry) String() string {
	return fmt.Sprintf("%s %s %s %s %s", e.TS, e.User, e.Action, e.Target, e.Result)
}
