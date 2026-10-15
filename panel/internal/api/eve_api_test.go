package api

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/eve"
)

func eveLine(typ string, n int) string {
	return fmt.Sprintf(`{"timestamp":"2026-10-15T10:00:%02d.000000+0000","event_type":%q,"n":%d,"alert":{"signature":"sig %d"}}`+"\n", n%60, typ, n, n)
}

func withEve(r *eve.Reader) option {
	return func(cfg *Config, _ string) { cfg.Eve = r }
}

type eveAnswer struct {
	Available   bool
	Reason      string
	FilePresent bool `json:"file_present"`
	Types       []string
	Events      []struct {
		ID    uint64
		Type  string
		Time  string
		Event map[string]any
	}
	Error string
}

func getEve(t *testing.T, e *env, cookies []*http.Cookie, query string) (int, eveAnswer) {
	t.Helper()
	w := e.do(req{method: "GET", path: "/api/eve" + query, cookies: cookies})
	var a eveAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &a); err != nil {
		t.Fatalf("not JSON: %q", w.Body)
	}
	return w.Code, a
}

func writeEve(t *testing.T, text string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "eve.json")
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// Criterion 1: at most the 50 newest alerts of the type asked for; 1000 is a
// 400 before anything is read.
func TestEveListLimitsAndFilters(t *testing.T) {
	var text string
	for i := 1; i <= 80; i++ {
		text += eveLine("alert", i)
		text += eveLine("dns", i)
	}
	e := setup(t, withEve(eve.New(writeEve(t, text))))
	cookies, _ := e.login()

	code, a := getEve(t, e, cookies, "?type=alert&limit=50")
	if code != 200 || !a.Available || !a.FilePresent || len(a.Events) != 50 {
		t.Fatalf("alerts: %d available=%v events=%d", code, a.Available, len(a.Events))
	}
	if a.Events[0].Event["n"] != float64(80) || a.Events[49].Event["n"] != float64(31) || a.Events[0].Type != "alert" {
		t.Errorf("newest first expected: %v ... %v", a.Events[0].Event["n"], a.Events[49].Event["n"])
	}
	if _, a := getEve(t, e, cookies, "?type=alert"); len(a.Events) != 50 {
		t.Errorf("default limit gave %d events, want 50", len(a.Events))
	}
	if _, a := getEve(t, e, cookies, "?type=dns&limit=2"); len(a.Events) != 2 || a.Events[0].Type != "dns" {
		t.Errorf("type filter: %+v", a.Events)
	}
	if _, a := getEve(t, e, cookies, "?type=alert&q=SIG%2012&limit=500"); len(a.Events) != 1 || a.Events[0].Event["n"] != float64(12) {
		t.Errorf("text filter: %+v", a.Events)
	}
	if code, a := getEve(t, e, cookies, "?type=alert&since=2026-10-15T10:00:70Z"); code != http.StatusBadRequest {
		t.Errorf("an impossible since: %d %q, want 400", code, a.Error)
	}
	// Seconds in the fixture are n%60: from :40 on, only n=40..59 qualify.
	if code, a := getEve(t, e, cookies, "?type=alert&since=2026-10-15T10:00:40Z&limit=500"); code != 200 || len(a.Events) != 20 {
		t.Errorf("since: %d, %d events, want 20", code, len(a.Events))
	}
	if len(a.Types) != 2 || a.Types[0] != "alert" {
		t.Errorf("types for the filter menu: %v", a.Types)
	}

	for _, bad := range []string{"?limit=1000", "?limit=501", "?limit=0", "?limit=-3", "?limit=abc", "?type=Alert", "?type=a%20b", "?type=" + strings.Repeat("a", 33), "?q=" + strings.Repeat("x", 101), "?since=yesterday"} {
		if code, _ := getEve(t, e, cookies, bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad, code)
		}
	}
	if code, _ := getEve(t, e, cookies, "?limit=500"); code != 200 {
		t.Errorf("limit=500 must be allowed: %d", code)
	}
}

// Criterion 5: with EVE_FILE=no the answer says so; an empty list would mean
// "nothing happened". A file that does not exist yet is a different thing.
func TestEveOffIsNotAnEmptyList(t *testing.T) {
	e := setup(t) // no reader: EVE_FILE=no
	cookies, _ := e.login()
	code, a := getEve(t, e, cookies, "?type=alert")
	if code != 200 || a.Available || !strings.Contains(a.Reason, "EVE_FILE=no") || len(a.Events) != 0 {
		t.Fatalf("off: %d %+v", code, a)
	}
	if code, _ := getEve(t, e, cookies, "?limit=1000"); code != http.StatusBadRequest {
		t.Errorf("a bad limit is a 400 even when the viewer is off: %d", code)
	}
	if w := e.do(req{method: "GET", path: "/api/eve/stream", cookies: cookies}); w.Code != http.StatusConflict {
		t.Errorf("stream while off: %d, want 409", w.Code)
	}

	missing := eve.New(filepath.Join(t.TempDir(), "eve.json"))
	e2 := setup(t, withEve(missing))
	cookies2, _ := e2.login()
	if code, a := getEve(t, e2, cookies2, ""); code != 200 || !a.Available || a.FilePresent || len(a.Events) != 0 {
		t.Errorf("no file yet: %d %+v", code, a)
	}
}

func TestEveNeedsASession(t *testing.T) {
	e := setup(t, withEve(eve.New(writeEve(t, eveLine("alert", 1)))))
	for _, p := range []string{"/api/eve", "/api/eve/stream"} {
		if w := e.do(req{method: "GET", path: p}); w.Code != http.StatusUnauthorized {
			t.Errorf("%s without a session: %d, want 401", p, w.Code)
		}
	}
}

func liveEve(t *testing.T, r *eve.Reader) (*httptest.Server, *http.Client) {
	t.Helper()
	policy, err := auth.NewPolicy("localhost", "")
	if err != nil {
		t.Fatal(err)
	}
	e := setup(t, withEve(r), func(c *Config, _ string) { c.Policy = policy })
	ts := httptest.NewServer(e.handler)
	t.Cleanup(ts.Close)
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: jar}
	resp, err := client.Post(ts.URL+"/api/login", "application/json", strings.NewReader(`{"password":"correct horse"}`))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("login: %v %v", err, resp)
	}
	resp.Body.Close()
	return ts, client
}

// Criterion 6: a stream carries only events that arrived after it opened,
// and only of the type chosen.
func TestEveStreamSendsOnlyNewEventsOfTheChosenType(t *testing.T) {
	old := evePollEvery
	evePollEvery = 20 * time.Millisecond
	t.Cleanup(func() { evePollEvery = old })

	path := writeEve(t, eveLine("alert", 1)+eveLine("dns", 2)) // already there: must not be sent
	ts, client := liveEve(t, eve.New(path))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hr, _ := http.NewRequestWithContext(ctx, "GET", ts.URL+"/api/eve/stream?type=alert", nil)
	resp, err := client.Do(hr)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("stream: %d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}

	h, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	h.WriteString(eveLine("dns", 3) + eveLine("alert", 4) + eveLine("flow", 5) + eveLine("alert", 6))
	h.Close()

	rd := bufio.NewReader(resp.Body)
	next := func() map[string]any {
		t.Helper()
		type result struct {
			ev  map[string]any
			err error
		}
		ch := make(chan result, 1)
		go func() {
			for {
				line, err := rd.ReadString('\n')
				if err != nil {
					ch <- result{err: err}
					return
				}
				if rest, ok := strings.CutPrefix(line, "data: "); ok {
					var ev map[string]any
					ch <- result{ev: ev, err: json.Unmarshal([]byte(rest), &ev)}
					return
				}
			}
		}()
		select {
		case r := <-ch:
			if r.err != nil {
				t.Fatalf("reading the stream: %v", r.err)
			}
			return r.ev
		case <-time.After(4 * time.Second):
			t.Fatal("no event in 4 seconds")
			return nil
		}
	}
	for _, want := range []float64{4, 6} {
		ev := next()
		inner, _ := ev["event"].(map[string]any)
		if ev["type"] != "alert" || inner["n"] != want {
			t.Fatalf("got %v, want the alert with n=%v", ev, want)
		}
	}
}

func TestEveStreamRefusesABadType(t *testing.T) {
	e := setup(t, withEve(eve.New(writeEve(t, ""))))
	cookies, _ := e.login()
	if w := e.do(req{method: "GET", path: "/api/eve/stream?type=A%20B", cookies: cookies}); w.Code != http.StatusBadRequest {
		t.Errorf("bad type: %d, want 400", w.Code)
	}
}
