// Package eve reads Suricata's eve.json for the Events screen.
//
// The file is never parsed as a whole: a Reader remembers how far it has
// read and, on every Poll, reads only what was appended since. It keeps the
// newest events in memory, per event type, in rings whose sizes add up to at
// most RingLimit (tech.md 9).
package eve

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	// PerTypeCap and MaxTypes together make the ring of tech.md 9: no more
	// than RingLimit events in memory.
	PerTypeCap = 500
	MaxTypes   = 10
	RingLimit  = PerTypeCap * MaxTypes

	// MaxLine is the longest line kept; a longer one is skipped whole.
	MaxLine = 64 << 10

	// StartBytes bounds the first read of a file and any catch-up after the
	// reader was idle: only this much of the end is looked at.
	StartBytes = 4 << 20

	chunk = 64 << 10
)

// Event is one line of eve.json that parsed.
type Event struct {
	ID   uint64    // grows by one per kept event, in file order
	Type string    // event_type
	Time time.Time // timestamp; zero if it did not parse
	Line []byte    // the line as written, without the newline
}

// Query selects events from memory, newest first.
type Query struct {
	Type  string    // empty means every type
	Text  string    // case-insensitive substring of the line; empty means any
	Since time.Time // events at or after this time; zero means any
	Limit int
}

// Reader follows one eve.json. Its methods are safe for concurrent use.
type Reader struct {
	path string

	mu       sync.Mutex
	f        *os.File
	info     os.FileInfo // of f when it was opened, to notice a replaced file
	offset   int64       // everything before it has been read from f
	lastRead int64       // bytes read by the latest Poll
	partial  []byte      // the unfinished last line read so far
	discard  bool        // drop bytes up to the next newline (we joined mid-line)
	nextID   uint64
	rings    map[string]*ring
	present  bool
}

// New returns a Reader for path. Nothing is read until Poll.
func New(path string) *Reader {
	return &Reader{path: path, rings: map[string]*ring{}, nextID: 1}
}

// Poll reads what was appended to the file since the last call.
//
// A file that was renamed away (log rotation) is read to its end through the
// handle that is still open before the reader moves to the new file, so
// nothing between the last Poll and the rotation is lost. A file that shrank
// (copy-truncate) is read again from its start. A missing file is not an
// error: Suricata may not have written it yet.
func (r *Reader) Poll() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lastRead = 0

	if r.f == nil {
		if err := r.open(); err != nil {
			return err
		}
		if r.f == nil {
			return nil
		}
	}
	if err := r.drain(); err != nil {
		return err
	}

	// Did the path start pointing at another file?
	st, err := os.Stat(r.path)
	if err == nil && !os.SameFile(st, r.info) {
		r.f.Close()
		r.f, r.info = nil, nil
		if err := r.open(); err != nil {
			return err
		}
		if r.f != nil {
			return r.drain()
		}
	}
	return nil
}

// open opens the file and positions at the start, or at the last StartBytes
// of a big file. A missing file leaves r.f nil.
func (r *Reader) open() error {
	f, err := os.Open(r.path)
	if errors.Is(err, os.ErrNotExist) {
		r.present = false
		return nil
	}
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	r.f, r.info, r.present = f, info, true
	r.offset, r.partial, r.discard = 0, nil, false
	if info.Size() > StartBytes {
		r.offset = info.Size() - StartBytes
		r.discard = true // we landed somewhere inside a line
	}
	return nil
}

// drain reads from the offset to the end of the open file.
func (r *Reader) drain() error {
	info, err := r.f.Stat()
	if err != nil {
		return err
	}
	size := info.Size()
	switch {
	case size < r.offset:
		// Truncated in place: start over from the beginning.
		r.offset, r.partial, r.discard = 0, nil, false
	case size-r.offset > StartBytes:
		// Idle for long: do not read gigabytes, look at the end only.
		r.offset, r.partial, r.discard = size-StartBytes, nil, true
	}

	buf := make([]byte, chunk)
	for {
		n, err := r.f.ReadAt(buf, r.offset)
		if n > 0 {
			r.offset += int64(n)
			r.lastRead += int64(n)
			r.feed(buf[:n])
		}
		if err == io.EOF || (err == nil && n == 0) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// feed splits data into lines and keeps the unfinished tail for the next
// call.
func (r *Reader) feed(data []byte) {
	for len(data) > 0 {
		nl := bytes.IndexByte(data, '\n')
		if r.discard {
			if nl < 0 {
				return
			}
			r.discard = false
			data = data[nl+1:]
			continue
		}
		if nl < 0 {
			r.partial = append(r.partial, data...)
			if len(r.partial) > MaxLine {
				// A line this long is not one of ours; skip its rest too.
				r.partial, r.discard = nil, true
			}
			return
		}
		line := data[:nl]
		if len(r.partial) > 0 {
			line = append(r.partial, line...)
			r.partial = nil
		}
		data = data[nl+1:]
		r.add(line)
	}
}

// add keeps one complete line if it is an event.
func (r *Reader) add(line []byte) {
	line = bytes.TrimRight(line, "\r")
	if len(line) == 0 || len(line) > MaxLine {
		return
	}
	var head struct {
		Type      string `json:"event_type"`
		Timestamp string `json:"timestamp"`
	}
	if err := json.Unmarshal(line, &head); err != nil || head.Type == "" {
		return // a broken or foreign line is skipped, not an error
	}
	rg := r.rings[head.Type]
	if rg == nil {
		if len(r.rings) == MaxTypes {
			return // the 5000-event budget is spent on the first types seen
		}
		rg = &ring{}
		r.rings[head.Type] = rg
	}
	rg.push(Event{
		ID:   r.nextID,
		Type: head.Type,
		Time: parseTime(head.Timestamp),
		Line: append([]byte(nil), line...),
	})
	r.nextID++
}

var timeLayouts = []string{"2006-01-02T15:04:05.999999-0700", time.RFC3339Nano}

func parseTime(s string) time.Time {
	for _, layout := range timeLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}

// Present reports whether the file existed at the last Poll.
func (r *Reader) Present() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.present
}

// Offset is how far into the open file the reader has read.
func (r *Reader) Offset() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.offset
}

// LastRead is the number of bytes the latest Poll read from the file.
func (r *Reader) LastRead() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastRead
}

// LastID is the ID of the newest event kept, 0 if there is none.
func (r *Reader) LastID() uint64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.nextID - 1
}

// Types lists the event types seen so far, sorted.
func (r *Reader) Types() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	types := make([]string, 0, len(r.rings))
	for t := range r.rings {
		types = append(types, t)
	}
	sort.Strings(types)
	return types
}

// Recent returns the events that match q, newest first, at most q.Limit.
func (r *Reader) Recent(q Query) []Event {
	needle := strings.ToLower(q.Text)
	out := r.collect(q.Type, func(e Event) bool {
		if !q.Since.IsZero() && e.Time.Before(q.Since) {
			return false
		}
		return needle == "" || strings.Contains(strings.ToLower(string(e.Line)), needle)
	})
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out
}

// After returns the events newer than id, oldest first. An empty typ means
// every type.
func (r *Reader) After(id uint64, typ string) []Event {
	out := r.collect(typ, func(e Event) bool { return e.ID > id })
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (r *Reader) collect(typ string, keep func(Event) bool) []Event {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []Event
	for t, rg := range r.rings {
		if typ != "" && t != typ {
			continue
		}
		rg.each(func(e Event) {
			if keep(e) {
				out = append(out, e)
			}
		})
	}
	return out
}

// ring keeps the newest PerTypeCap events of one type.
type ring struct {
	buf   []Event
	start int
}

func (g *ring) push(e Event) {
	if len(g.buf) < PerTypeCap {
		g.buf = append(g.buf, e)
		return
	}
	g.buf[g.start] = e
	g.start = (g.start + 1) % PerTypeCap
}

func (g *ring) each(f func(Event)) {
	for i := range g.buf {
		f(g.buf[(g.start+i)%len(g.buf)])
	}
}
