package audit

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newLog(t *testing.T) *Log {
	t.Helper()
	base := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	n := 0
	return &Log{
		Path: filepath.Join(t.TempDir(), "audit.jsonl"),
		Now:  func() time.Time { n++; return base.Add(time.Duration(n) * time.Minute) },
	}
}

func TestAnEntryIsOneLineAndReadBackNewestFirst(t *testing.T) {
	l := newLog(t)
	for _, a := range []string{"login", "settings.apply", "logout"} {
		if err := l.Write(Entry{User: "admin", IP: "192.168.1.5", Action: a}); err != nil {
			t.Fatal(err)
		}
	}
	data, _ := os.ReadFile(l.Path)
	if got := strings.Count(string(data), "\n"); got != 3 {
		t.Fatalf("%d lines, want 3", got)
	}
	list, err := l.Read(Filter{})
	if err != nil || len(list) != 3 {
		t.Fatalf("read: %v %d", err, len(list))
	}
	if list[0].Action != "logout" || list[2].Action != "login" {
		t.Errorf("order: %v", list)
	}
	if list[0].Result != ResultOK {
		t.Errorf("default result %q", list[0].Result)
	}
}

func TestANewlineInAFieldCannotMakeASecondLine(t *testing.T) {
	l := newLog(t)
	if err := l.Write(Entry{User: "x\n{\"user\":\"admin\"}", Action: "a\r\nb", Target: "t\x00"}); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(l.Path)
	if strings.Count(string(data), "\n") != 1 {
		t.Errorf("more than one line: %q", data)
	}
	list, _ := l.Read(Filter{})
	if len(list) != 1 || strings.ContainsAny(list[0].User+list[0].Action+list[0].Target, "\n\r\x00") {
		t.Errorf("entry: %+v", list)
	}
}

func TestFilters(t *testing.T) {
	l := newLog(t)
	_ = l.Write(Entry{User: "admin", Action: "POST /api/login", Result: ResultOK})
	_ = l.Write(Entry{User: "anna", Action: "POST /api/login", Result: ResultDenied})
	_ = l.Write(Entry{User: "anna", Action: "PUT /api/settings/apply", Result: ResultOK})
	cases := []struct {
		name string
		f    Filter
		want int
	}{
		{"user", Filter{User: "anna"}, 2},
		{"result", Filter{Result: ResultDenied}, 1},
		{"action substring, case-insensitive", Filter{Action: "SETTINGS"}, 1},
		{"limit", Filter{Limit: 1}, 1},
		{"since", Filter{Since: time.Date(2026, 11, 1, 12, 2, 0, 0, time.UTC)}, 2},
		{"until", Filter{Until: time.Date(2026, 11, 1, 12, 1, 0, 0, time.UTC)}, 1},
	}
	for _, c := range cases {
		list, err := l.Read(c.f)
		if err != nil || len(list) != c.want {
			t.Errorf("%s: %d entries (%v), want %d", c.name, len(list), err, c.want)
		}
	}
}

func TestRotationKeepsFiveFilesAndReadsAcrossThem(t *testing.T) {
	l := newLog(t)
	l.MaxBytes = 300
	for i := 0; i < 60; i++ {
		if err := l.Write(Entry{User: "admin", Action: "tick", Target: strings.Repeat("x", 40)}); err != nil {
			t.Fatal(err)
		}
	}
	entries, _ := os.ReadDir(filepath.Dir(l.Path))
	if len(entries) > DefaultKeep {
		t.Errorf("%d files, at most %d", len(entries), DefaultKeep)
	}
	if _, err := os.Stat(l.Path + ".1"); err != nil {
		t.Errorf("no rotated file: %v", err)
	}
	list, err := l.Read(Filter{Limit: MaxRead})
	if err != nil || len(list) < 10 {
		t.Errorf("read across files: %d %v", len(list), err)
	}
	for i := 1; i < len(list); i++ {
		if list[i-1].TS < list[i].TS {
			t.Fatal("not newest first across files")
		}
	}
}

func TestAnUnsetLogDoesNothing(t *testing.T) {
	var l *Log
	if err := l.Write(Entry{Action: "x"}); err != nil {
		t.Error(err)
	}
	if list, err := (&Log{}).Read(Filter{}); err != nil || list != nil {
		t.Errorf("%v %v", list, err)
	}
}

func TestADamagedLineIsSkipped(t *testing.T) {
	l := newLog(t)
	_ = l.Write(Entry{User: "a", Action: "one"})
	f, _ := os.OpenFile(l.Path, os.O_APPEND|os.O_WRONLY, 0o660)
	_, _ = f.WriteString("{not json\n")
	f.Close()
	_ = l.Write(Entry{User: "a", Action: "two"})
	list, _ := l.Read(Filter{})
	if len(list) != 2 {
		t.Errorf("%d entries, want 2", len(list))
	}
}

func TestCSVNeutralisesFormulas(t *testing.T) {
	var b bytes.Buffer
	if err := WriteCSV(&b, []Entry{{TS: "t", User: "=cmd|' /C calc'!A0", Action: "a", Result: "ok"}}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(b.String(), "\n=cmd") || strings.Contains(b.String(), ",=cmd") {
		t.Errorf("formula not neutralised: %q", b.String())
	}
	if !strings.HasPrefix(b.String(), "ts,user,ip,action,target,result,detail\n") {
		t.Errorf("header: %q", b.String())
	}
}
