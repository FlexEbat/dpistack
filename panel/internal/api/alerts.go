package api

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
)

const (
	alertsDefault = 100
	alertsMax     = 500
	// alertsTail is how much of the end of events.jsonl is looked at: the
	// file only grows, and the screen wants the newest.
	alertsTail = 1 << 20
)

var checkID = regexp.MustCompile(`^[a-z0-9_.-]{1,64}$`)

// alert is one line of events.jsonl: a check changed its status.
type alert struct {
	TS     string `json:"ts"`
	Check  string `json:"check"`
	From   string `json:"from"`
	To     string `json:"to"`
	Detail string `json:"detail"`
}

// alertsList handles GET /api/alerts?limit=&check=: the lines of
// events.jsonl, newest first, optionally of one check.
func (s *server) alertsList(w http.ResponseWriter, r *http.Request) {
	limit := alertsDefault
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > alertsMax {
			writeError(w, http.StatusBadRequest, "limit: целое число от 1 до "+strconv.Itoa(alertsMax))
			return
		}
		limit = n
	}
	check := r.URL.Query().Get("check")
	if check != "" && !checkID.MatchString(check) {
		writeError(w, http.StatusBadRequest, "check: идентификатор проверки, например disk.free")
		return
	}

	events, present := readAlerts(s.cfg.EventsFile)
	seen := map[string]bool{}
	for _, a := range events {
		seen[a.Check] = true
	}
	checks := make([]string, 0, len(seen))
	for c := range seen {
		checks = append(checks, c)
	}
	sort.Strings(checks)

	out := []alert{}
	for i := len(events) - 1; i >= 0 && len(out) < limit; i-- { // the file is oldest first
		if check == "" || events[i].Check == check {
			out = append(out, events[i])
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"alerts":       out,
		"checks":       checks,
		"file_present": present,
	})
}

// readAlerts reads the tail of events.jsonl, oldest first. A line that is
// not an event is skipped, as is the first one if the tail cut it.
func readAlerts(path string) ([]alert, bool) {
	if path == "" {
		return nil, false
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, true
	}
	cut := st.Size() > alertsTail
	if cut {
		if _, err := f.Seek(st.Size()-alertsTail, io.SeekStart); err != nil {
			return nil, true
		}
	}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<10), 256<<10)
	var events []alert
	for first := true; sc.Scan(); first = false {
		if cut && first {
			continue // the tail starts inside a line
		}
		line := bytes.TrimSpace(sc.Bytes())
		var a alert
		if len(line) == 0 || json.Unmarshal(line, &a) != nil || a.Check == "" {
			continue
		}
		events = append(events, a)
	}
	return events, true
}
