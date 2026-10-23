package api

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	logsDefault   = 200
	streamDefault = 50
	logsMax       = 1000 // the limit of `ctl logs -n`
	maxStreams    = 4    // each stream is a sudo and a journalctl process
	pingEvery     = 15 * time.Second
	writeWindow   = 10 * time.Second
	beginAfter    = 300 * time.Millisecond
)

// parseLines reads ?lines=; the limit is dpistack's own.
func parseLines(r *http.Request, def int) (int, bool) {
	raw := r.URL.Query().Get("lines")
	if raw == "" {
		return def, true
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > logsMax {
		return 0, false
	}
	return n, true
}

// logs handles GET /api/logs/{id}?lines=N.
func (s *server) logs(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !componentID.MatchString(id) {
		writeError(w, http.StatusNotFound, "нет такого компонента")
		return
	}
	n, ok := parseLines(r, logsDefault)
	if !ok {
		writeError(w, http.StatusBadRequest, "lines: целое число от 1 до "+strconv.Itoa(logsMax))
		return
	}
	lines, err := s.cfg.Ctl.Logs(r.Context(), id, n)
	if err != nil {
		ctlError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "lines": lines})
}

// sse writes server-sent events. Nothing is sent until begin, so an error
// that comes first (no such component) can still be a plain HTTP error.
type sse struct {
	mu     sync.Mutex
	w      http.ResponseWriter
	rc     *http.ResponseController
	began  bool
	closed bool
}

func sseHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no") // nginx must not hold the stream back
	w.WriteHeader(http.StatusOK)
}

func (e *sse) beginLocked() {
	if e.began || e.closed {
		return
	}
	e.began = true
	sseHeaders(e.w)
}

func (e *sse) begin() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.beginLocked()
	e.flushLocked("")
}

// write sends one raw chunk.
func (e *sse) write(chunk string) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.closed {
		return errors.New("stream closed")
	}
	e.beginLocked()
	return e.flushLocked(chunk)
}

func (e *sse) flushLocked(chunk string) error {
	// The server's WriteTimeout would cut a long stream; each write gets its
	// own short window instead, so a stalled client cannot hold it forever.
	_ = e.rc.SetWriteDeadline(time.Now().Add(writeWindow))
	if chunk != "" {
		if _, err := e.w.Write([]byte(chunk)); err != nil {
			return err
		}
	}
	return e.rc.Flush()
}

// sseOneLine makes text safe for one "data:" field. A lone CR ends a line in
// an event stream too: a log line with "\r" in it could otherwise start a
// field of its own ("event:", "id:").
func sseOneLine(s string) string {
	return strings.NewReplacer("\r", " ", "\n", " ").Replace(s)
}

func (e *sse) data(line string) error {
	return e.write("data: " + sseOneLine(line) + "\n\n")
}

// finish stops any later write and reports whether the stream had begun.
func (e *sse) finish() (began bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.closed = true
	return e.began
}

func (s *server) takeStream() bool {
	if s.streams.Add(1) > int32(s.maxStreams()) {
		s.streams.Add(-1)
		return false
	}
	return true
}

// logStream handles GET /api/logs/{id}/stream: the last lines, then new ones
// as they come. When the browser goes away the request context ends, Follow
// closes the stdin of ctl, and ctl stops journalctl: no process is left.
func (s *server) logStream(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !componentID.MatchString(id) {
		writeError(w, http.StatusNotFound, "нет такого компонента")
		return
	}
	n, ok := parseLines(r, streamDefault)
	if !ok {
		writeError(w, http.StatusBadRequest, "lines: целое число от 1 до "+strconv.Itoa(logsMax))
		return
	}
	if !s.takeStream() {
		writeError(w, http.StatusTooManyRequests, "слишком много открытых потоков логов, закройте лишние вкладки")
		return
	}
	defer s.streams.Add(-1)

	st := &sse{w: w, rc: http.NewResponseController(w)}
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	// A quiet journal must not leave the browser waiting for headers.
	timer := time.AfterFunc(beginAfter, st.begin)
	defer timer.Stop()
	ping := time.NewTicker(pingEvery)
	defer ping.Stop()
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case <-ping.C:
				if err := st.write(": ping\n\n"); err != nil {
					cancel()
					return
				}
			}
		}
	}()

	err := s.cfg.Ctl.Follow(ctx, id, n, st.data)
	began := st.finish()
	if ctx.Err() != nil {
		return // the client left
	}
	switch {
	case err != nil && !began:
		ctlError(w, err)
	case err != nil:
		// Headers are gone; the error travels as an event.
		_, _ = w.Write([]byte("event: error\ndata: " + sseOneLine(errText(err)) + "\n\n"))
		_ = st.rc.Flush()
	default:
		if !began {
			sseHeaders(w)
		}
		_, _ = w.Write([]byte("event: end\ndata: журнал закрыт\n\n"))
		_ = st.rc.Flush()
	}
}
