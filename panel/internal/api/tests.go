package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// testsAllowance is how long the answer to a test run may take to write.
const testsAllowance = ctl.TestTimeout + time.Minute

// opState holds the "one at a time" flags of the operations that change the
// system and take long: the tests and the interface list.
type opState struct {
	mu           sync.Mutex
	testsRunning bool
	ifaceBusy    bool
	modeBusy     bool
	settingsBusy bool
}

func (o *opState) begin(flag *bool) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if *flag {
		return false
	}
	*flag = true
	return true
}

func (o *opState) end(flag *bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	*flag = false
}

func (o *opState) testsAreRunning() bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.testsRunning
}

// testResult is one test as ctl writes it.
type testResult struct {
	Name       string `json:"name"`
	Status     string `json:"status"`
	Detail     string `json:"detail"`
	DurationMS int64  `json:"duration_ms"`
	Timestamp  string `json:"timestamp,omitempty"`
}

// parseTestResults reads the array `ctl test --json` printed. Anything ctl
// wrote before it is skipped: the array is the last line that starts with [.
func parseTestResults(out []byte) ([]testResult, bool) {
	lines := bytes.Split(bytes.TrimSpace(out), []byte("\n"))
	for i := len(lines) - 1; i >= 0; i-- {
		line := bytes.TrimSpace(lines[i])
		if len(line) == 0 || line[0] != '[' {
			continue
		}
		var res []testResult
		if json.Unmarshal(line, &res) == nil {
			return res, true
		}
	}
	return nil, false
}

// testsRun handles POST /api/tests/{bittorrent|https|all}. The answer is
// what `ctl test --json` printed: one object per test with a status of
// pass, fail or skip. A test that failed is a result, not an error.
//
// ctl runs detached from the request, as the rules update does: a test that
// is killed halfway could leave its rule or its traffic behind. One run at
// a time.
func (s *server) testsRun(w http.ResponseWriter, r *http.Request) {
	which := r.PathValue("which")
	if which != "bittorrent" && which != "https" && which != "all" {
		writeError(w, http.StatusNotFound, "нет такого теста")
		return
	}
	if !s.ops.begin(&s.ops.testsRunning) {
		writeError(w, http.StatusConflict, "тесты уже идут")
		return
	}
	defer s.ops.end(&s.ops.testsRunning)
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(testsAllowance))

	out, err := s.cfg.Ctl.TestRun(context.WithoutCancel(r.Context()), which)
	var exit *ctl.ExitError
	if errors.As(err, &exit) && exit.Code == 1 {
		out, err = []byte(exit.Output), nil // some test failed: the results are still the answer
	}
	if err != nil {
		opError(w, err)
		return
	}
	results, ok := parseTestResults(out)
	if !ok {
		writeError(w, http.StatusInternalServerError, "dpistack test не вернул результатов")
		return
	}
	writeJSON(w, http.StatusOK, results)
}

// testsLast handles GET /api/tests/last: the last result of every test, from
// tests-last.json, so it outlives the panel's restarts. A missing or damaged
// file is an empty list.
func (s *server) testsLast(w http.ResponseWriter, r *http.Request) {
	results := []testResult{}
	if s.cfg.TestsFile != "" {
		if data, err := os.ReadFile(s.cfg.TestsFile); err == nil {
			var f struct {
				Results []testResult `json:"results"`
			}
			if json.Unmarshal(data, &f) == nil && f.Results != nil {
				results = f.Results
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"results": results,
		"running": s.ops.testsAreRunning(),
	})
}
