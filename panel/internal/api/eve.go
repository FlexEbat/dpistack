package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/eve"
)

const (
	eveDefault = 50
	eveMax     = 500 // tech.md 4.8: limit up to 500
)

// evePollEvery is how often a stream looks at the file. A variable so tests
// need not wait a second.
var evePollEvery = time.Second

var eveType = regexp.MustCompile(`^[a-z0-9_]{1,32}$`)

const eveOff = "просмотр событий выключен (EVE_FILE=no)"

// eveEvent is one event as the screen gets it: the line itself is kept
// intact under "event".
type eveEvent struct {
	ID    uint64          `json:"id"`
	Type  string          `json:"type"`
	Time  string          `json:"time,omitempty"`
	Event json.RawMessage `json:"event"`
}

func toEveEvent(e eve.Event) eveEvent {
	out := eveEvent{ID: e.ID, Type: e.Type, Event: json.RawMessage(e.Line)}
	if !e.Time.IsZero() {
		out.Time = e.Time.UTC().Format(time.RFC3339Nano)
	}
	return out
}

// eveQuery reads ?type=, ?q= and ?since= (the limit is separate); a bad
// value is a sentence for the screen, not a silent default.
func eveQuery(r *http.Request) (eve.Query, string) {
	var q eve.Query
	v := r.URL.Query()
	q.Type = v.Get("type")
	if q.Type != "" && !eveType.MatchString(q.Type) {
		return q, "type: строчные латинские буквы, цифры и _ (до 32 знаков)"
	}
	q.Text = strings.TrimSpace(v.Get("q"))
	if len([]rune(q.Text)) > 100 {
		return q, "q: не длиннее 100 знаков"
	}
	if raw := v.Get("since"); raw != "" {
		t, err := time.Parse(time.RFC3339Nano, raw)
		if err != nil {
			return q, "since: время в формате RFC 3339, например 2026-10-15T10:00:00Z"
		}
		q.Since = t
	}
	return q, ""
}

// eveList handles GET /api/eve?type=&q=&since=&limit=.
//
// With EVE_FILE=no the answer says the viewer is off (available false); an
// empty list would read as "no events", which is a different statement.
func (s *server) eveList(w http.ResponseWriter, r *http.Request) {
	limit := eveDefault
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > eveMax {
			writeError(w, http.StatusBadRequest, "limit: целое число от 1 до "+strconv.Itoa(eveMax))
			return
		}
		limit = n
	}
	q, bad := eveQuery(r)
	if bad != "" {
		writeError(w, http.StatusBadRequest, bad)
		return
	}
	q.Limit = limit

	if s.cfg.Eve == nil {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "reason": eveOff, "events": []eveEvent{}})
		return
	}
	if err := s.cfg.Eve.Poll(); err != nil {
		writeError(w, http.StatusInternalServerError, "не удалось прочитать eve.json: "+err.Error())
		return
	}
	events := []eveEvent{}
	for _, e := range s.cfg.Eve.Recent(q) {
		events = append(events, toEveEvent(e))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"available":    true,
		"file_present": s.cfg.Eve.Present(),
		"types":        s.cfg.Eve.Types(),
		"events":       events,
	})
}

// eveStream handles GET /api/eve/stream?type=: Server-Sent Events with the
// events that arrive after the connection was made, of the chosen type
// only. It counts against the same cap as log streams.
func (s *server) eveStream(w http.ResponseWriter, r *http.Request) {
	typ := r.URL.Query().Get("type")
	if typ != "" && !eveType.MatchString(typ) {
		writeError(w, http.StatusBadRequest, "type: строчные латинские буквы, цифры и _ (до 32 знаков)")
		return
	}
	if s.cfg.Eve == nil {
		writeError(w, http.StatusConflict, eveOff)
		return
	}
	if !s.takeStream() {
		writeError(w, http.StatusTooManyRequests, "слишком много открытых потоков, закройте лишние вкладки")
		return
	}
	defer s.streams.Add(-1)

	// Catch up with the file first, so that only what comes later is sent.
	if err := s.cfg.Eve.Poll(); err != nil {
		writeError(w, http.StatusInternalServerError, "не удалось прочитать eve.json: "+err.Error())
		return
	}
	cursor := s.cfg.Eve.LastID()

	st := &sse{w: w, rc: http.NewResponseController(w)}
	st.begin()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer st.finish()

	poll := time.NewTicker(evePollEvery)
	defer poll.Stop()
	ping := time.NewTicker(pingEvery)
	defer ping.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ping.C:
			if err := st.write(": ping\n\n"); err != nil {
				return
			}
		case <-poll.C:
			if err := s.cfg.Eve.Poll(); err != nil {
				_ = st.write("event: error\ndata: " + errText(err) + "\n\n")
				return
			}
			// Every type is read so the cursor moves past events of other
			// types too; the choice of type is applied when sending.
			for _, e := range s.cfg.Eve.After(cursor, "") {
				cursor = e.ID
				if typ != "" && e.Type != typ {
					continue
				}
				data, err := json.Marshal(toEveEvent(e))
				if err != nil {
					continue
				}
				if err := st.write(fmt.Sprintf("id: %d\ndata: %s\n\n", e.ID, data)); err != nil {
					return
				}
			}
		}
	}
}
