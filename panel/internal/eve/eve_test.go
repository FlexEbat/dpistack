package eve

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// line builds one eve.json line of the given type.
func line(typ string, n int) string {
	return fmt.Sprintf(`{"timestamp":"2026-10-15T10:%02d:%02d.000000+0000","event_type":%q,"n":%d}`+"\n",
		n/60%60, n%60, typ, n)
}

type file struct {
	t    *testing.T
	path string
}

func newFile(t *testing.T) *file {
	return &file{t: t, path: filepath.Join(t.TempDir(), "eve.json")}
}

func (f *file) write(text string) {
	f.t.Helper()
	if err := os.WriteFile(f.path, []byte(text), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

func (f *file) append(text string) {
	f.t.Helper()
	h, err := os.OpenFile(f.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		f.t.Fatal(err)
	}
	defer h.Close()
	if _, err := h.WriteString(text); err != nil {
		f.t.Fatal(err)
	}
}

func poll(t *testing.T, r *Reader) {
	t.Helper()
	if err := r.Poll(); err != nil {
		t.Fatalf("Poll: %v", err)
	}
}

func ns(events []Event) []int {
	var out []int
	for _, e := range events {
		var n int
		fmt.Sscanf(string(e.Line[strings.Index(string(e.Line), `"n":`):]), `"n":%d`, &n)
		out = append(out, n)
	}
	return out
}

func equal(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Criterion 1 (the reader's half): the newest events of a type come back
// newest first and never more than the limit.
func TestRecentIsNewestFirstAndLimited(t *testing.T) {
	f := newFile(t)
	var text string
	for i := 1; i <= 60; i++ {
		text += line("alert", i)
		if i%3 == 0 {
			text += line("dns", i)
		}
	}
	f.write(text)
	r := New(f.path)
	poll(t, r)

	got := ns(r.Recent(Query{Type: "alert", Limit: 50}))
	if len(got) != 50 || got[0] != 60 || got[49] != 11 {
		t.Fatalf("alerts: %v", got)
	}
	if got := ns(r.Recent(Query{Type: "dns", Limit: 3})); !equal(got, []int{60, 57, 54}) {
		t.Fatalf("dns: %v", got)
	}
	all := ns(r.Recent(Query{Limit: 4}))
	if !equal(all, []int{60, 60, 59, 58}) {
		t.Fatalf("all types by arrival: %v", all)
	}
	if got := r.Types(); len(got) != 2 || got[0] != "alert" || got[1] != "dns" {
		t.Fatalf("types: %v", got)
	}
}

func TestRecentTextAndSince(t *testing.T) {
	f := newFile(t)
	f.write(`{"timestamp":"2026-10-15T10:00:00.000000+0000","event_type":"alert","alert":{"signature":"ET SCAN SSH"}}` + "\n" +
		`{"timestamp":"2026-10-15T11:00:00.000000+0000","event_type":"alert","alert":{"signature":"ET MALWARE x"}}` + "\n")
	r := New(f.path)
	poll(t, r)

	if got := r.Recent(Query{Type: "alert", Text: "scan ssh", Limit: 10}); len(got) != 1 {
		t.Errorf("case-insensitive text: %d events", len(got))
	}
	since := time.Date(2026, 10, 15, 10, 30, 0, 0, time.UTC)
	got := r.Recent(Query{Type: "alert", Since: since, Limit: 10})
	if len(got) != 1 || !strings.Contains(string(got[0].Line), "MALWARE") {
		t.Errorf("since: %v", got)
	}
}

// Criterion 2: after one line is appended, the next Poll reads that line and
// nothing before it.
func TestIncrementalReadTouchesOnlyNewBytes(t *testing.T) {
	f := newFile(t)
	f.write(line("alert", 1) + line("alert", 2) + line("alert", 3))
	r := New(f.path)
	poll(t, r)
	size := int64(len(line("alert", 1) + line("alert", 2) + line("alert", 3)))
	if r.Offset() != size || r.LastRead() != size {
		t.Fatalf("first poll: offset %d, read %d, want %d", r.Offset(), r.LastRead(), size)
	}

	poll(t, r)
	if r.LastRead() != 0 {
		t.Errorf("a poll with nothing new read %d bytes", r.LastRead())
	}

	next := line("alert", 4)
	f.append(next)
	poll(t, r)
	if r.LastRead() != int64(len(next)) {
		t.Errorf("read %d bytes for a %d-byte line", r.LastRead(), len(next))
	}
	if r.Offset() != size+int64(len(next)) {
		t.Errorf("offset %d, want %d", r.Offset(), size+int64(len(next)))
	}
	if got := ns(r.After(3, "alert")); !equal(got, []int{4}) {
		t.Errorf("new events: %v", got)
	}
	if r.LastID() != 4 {
		t.Errorf("last id %d, want 4", r.LastID())
	}
}

// Criterion 3: a file renamed away keeps its unread tail, the new file is
// followed from its start, and no event is read twice.
func TestRotationByRenameLosesNothing(t *testing.T) {
	f := newFile(t)
	f.write(line("alert", 1) + line("alert", 2))
	r := New(f.path)
	poll(t, r)

	// Between two polls: more lines arrive, the file is rotated, and the new
	// file already holds more bytes than the old offset.
	f.append(line("alert", 3))
	if err := os.Rename(f.path, f.path+".1"); err != nil {
		t.Fatal(err)
	}
	f.write(line("alert", 4) + line("alert", 5) + line("alert", 6) + line("alert", 7))
	poll(t, r)

	if got := ns(r.Recent(Query{Type: "alert", Limit: 20})); !equal(got, []int{7, 6, 5, 4, 3, 2, 1}) {
		t.Fatalf("after rotation: %v", got)
	}
	f.append(line("alert", 8))
	poll(t, r)
	if got := ns(r.After(7, "alert")); !equal(got, []int{8}) {
		t.Fatalf("after rotation, the new file is followed: %v", got)
	}

	// Rotation where the old file is gone and the new one does not exist yet.
	if err := os.Rename(f.path, f.path+".2"); err != nil {
		t.Fatal(err)
	}
	poll(t, r)
	f.write(line("alert", 9))
	poll(t, r)
	if got := ns(r.After(8, "alert")); !equal(got, []int{9}) {
		t.Fatalf("file appears after a gap: %v", got)
	}
}

func TestCopyTruncateIsReadFromTheStart(t *testing.T) {
	f := newFile(t)
	f.write(line("alert", 1) + line("alert", 2) + line("alert", 3))
	r := New(f.path)
	poll(t, r)

	f.write(line("alert", 4)) // same file, now shorter than the offset
	poll(t, r)
	if got := ns(r.After(3, "alert")); !equal(got, []int{4}) {
		t.Fatalf("after truncate: %v", got)
	}
}

// Criterion 4: a broken line is skipped, an unfinished last line waits for
// its end, neither is an error.
func TestBrokenAndUnfinishedLines(t *testing.T) {
	f := newFile(t)
	good := line("alert", 1)
	f.write(good + "this is not json\n" + `{"event_type":` + "\n" + "\n" + `{"no_type":1}` + "\n" + line("alert", 2) + `{"timestamp":"2026-10-15T10:00:03.000000+0000","event_type":"al`)
	r := New(f.path)
	poll(t, r)
	if got := ns(r.Recent(Query{Type: "alert", Limit: 10})); !equal(got, []int{2, 1}) {
		t.Fatalf("good lines around the broken ones: %v", got)
	}

	f.append(`ert","n":3}` + "\n")
	poll(t, r)
	if got := ns(r.After(2, "alert")); !equal(got, []int{3}) {
		t.Fatalf("the unfinished line, once finished: %v", got)
	}

	// An unfinished line that is garbage stays quiet and does not poison
	// the lines after it.
	f.append(`{"event_type":"alert",` + "\n")
	f.append(line("alert", 4))
	poll(t, r)
	if got := ns(r.After(3, "alert")); !equal(got, []int{4}) {
		t.Fatalf("after a bad line: %v", got)
	}
}

// The file is never parsed whole: a big file is entered at its last
// StartBytes, and the line cut by that is dropped.
func TestBigFileIsNotReadWhole(t *testing.T) {
	f := newFile(t)
	h, err := os.Create(f.path)
	if err != nil {
		t.Fatal(err)
	}
	pad := strings.Repeat("x", 900)
	total := 0
	for total < 3*StartBytes {
		s := fmt.Sprintf(`{"event_type":"flow","n":%d,"pad":%q}`+"\n", total, pad)
		h.WriteString(s)
		total += len(s)
	}
	h.Close()

	r := New(f.path)
	poll(t, r)
	if r.LastRead() > StartBytes {
		t.Fatalf("first poll read %d bytes of a %d-byte file, want at most %d", r.LastRead(), total, StartBytes)
	}
	got := r.Recent(Query{Type: "flow", Limit: 1000})
	if len(got) != PerTypeCap {
		t.Fatalf("ring holds %d flow events, want the cap %d", len(got), PerTypeCap)
	}
	for _, e := range got {
		if !strings.HasPrefix(string(e.Line), `{"event_type":"flow"`) {
			t.Fatalf("a cut line got through: %.60s", e.Line)
		}
	}
}

// After a long idle the reader catches up from the end, not from where it
// stopped.
func TestIdleReaderCatchesUpFromTheEnd(t *testing.T) {
	f := newFile(t)
	f.write(line("alert", 1))
	r := New(f.path)
	poll(t, r)

	h, err := os.OpenFile(f.path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	pad := strings.Repeat("y", 900)
	for written := 0; written < 2*StartBytes; {
		s := fmt.Sprintf(`{"event_type":"flow","pad":%q}`+"\n", pad)
		h.WriteString(s)
		written += len(s)
	}
	h.WriteString(line("alert", 2))
	h.Close()

	poll(t, r)
	if r.LastRead() > StartBytes {
		t.Fatalf("catch-up read %d bytes, want at most %d", r.LastRead(), StartBytes)
	}
	if got := ns(r.After(1, "alert")); !equal(got, []int{2}) {
		t.Fatalf("newest event after a catch-up: %v", got)
	}
}

// The ring is bounded: 500 per type, 10 types, 5000 in all.
func TestRingLimits(t *testing.T) {
	f := newFile(t)
	var text string
	for i := 1; i <= PerTypeCap+100; i++ {
		text += line("alert", i)
	}
	for i := 0; i < MaxTypes+3; i++ {
		text += line(fmt.Sprintf("type%02d", i), i)
	}
	f.write(text)
	r := New(f.path)
	poll(t, r)

	got := ns(r.Recent(Query{Type: "alert", Limit: 1000}))
	if len(got) != PerTypeCap || got[0] != PerTypeCap+100 || got[len(got)-1] != 101 {
		t.Fatalf("alert ring: %d events, from %d to %d", len(got), got[0], got[len(got)-1])
	}
	if n := len(r.Types()); n != MaxTypes {
		t.Fatalf("%d types kept, want %d", n, MaxTypes)
	}
	if RingLimit != 5000 {
		t.Fatalf("RingLimit is %d, tech.md says 5000", RingLimit)
	}
}

func TestMissingFileIsNotAnError(t *testing.T) {
	f := newFile(t)
	r := New(f.path)
	poll(t, r)
	if r.Present() {
		t.Error("a file that does not exist is present")
	}
	if len(r.Recent(Query{Limit: 10})) != 0 {
		t.Error("events from nowhere")
	}
	f.write(line("alert", 1))
	poll(t, r)
	if !r.Present() || len(r.Recent(Query{Limit: 10})) != 1 {
		t.Error("the file that appeared later is not followed")
	}
}
