package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A log line is attacker-influenced text (network content ends up in logs).
// Whatever it holds, it must stay inside one "data:" field of the stream.
func TestSSEDataStaysOneField(t *testing.T) {
	for _, line := range []string{
		"plain",
		"two\nlines",
		"cr only\revent: error",
		"crlf\r\nid: 7",
		"mixed\r\revent: x\n\nid: 1",
	} {
		rec := httptest.NewRecorder()
		e := &sse{w: rec, rc: http.NewResponseController(rec)}
		if err := e.data(line); err != nil {
			t.Fatalf("%q: %v", line, err)
		}
		out := rec.Body.String()
		if !strings.HasPrefix(out, "data: ") || !strings.HasSuffix(out, "\n\n") {
			t.Fatalf("%q: not one event: %q", line, out)
		}
		body := strings.TrimSuffix(out, "\n\n")
		if strings.ContainsAny(body, "\r\n") {
			t.Fatalf("%q: a line break inside the event: %q", line, out)
		}
	}
}
