package api

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/auth"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// fakeCtl is a dpistack stand-in that logs every call. Like the real
// one it answers 4 for a component that is not installed and 5 for one that
// does not exist, and its `logs --until-stdin-closed` runs until stdin closes.
type fakeCtl struct {
	runner  *ctl.Runner
	callLog string
	pidFile string
}

func newFakeCtl(t *testing.T) *fakeCtl {
	t.Helper()
	dir := t.TempDir()
	f := &fakeCtl{callLog: filepath.Join(dir, "calls"), pidFile: filepath.Join(dir, "pid")}
	script := `#!/bin/sh
echo "$*" >> '` + f.callLog + `'
case "$1" in
status) printf '%s' '` + statusJSON + `' ;;
start|stop|restart)
  case "$2" in
  redis) echo "dpistack: component not installed: redis" >&2; exit 4 ;;
  suricata|panel|ntopng) echo "done" ;;
  *) echo "dpistack: unknown component: $2" >&2; exit 5 ;;
  esac ;;
reload) echo "rules reloaded" ;;
logs)
  case "$2" in
  nosuch) echo "dpistack: unknown component: nosuch" >&2; exit 5 ;;
  esac
  case "$*" in
  *--until-stdin-closed*)
    echo $$ >> '` + f.pidFile + `'
    echo "first line"
    cat > /dev/null ;;
  *) printf 'line one\nline two\n' ;;
  esac ;;
esac
`
	path := filepath.Join(dir, "ctl")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.runner = &ctl.Runner{Path: path}
	return f
}

func (f *fakeCtl) calls(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile(f.callLog)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func (f *fakeCtl) called(t *testing.T, want string) bool {
	for _, c := range f.calls(t) {
		if c == want {
			return true
		}
	}
	return false
}

func (f *fakeCtl) callsStarting(t *testing.T, prefix string) int {
	n := 0
	for _, c := range f.calls(t) {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

func withCtl(f *fakeCtl) option {
	return func(c *Config, _ string) { c.Ctl = f.runner }
}

func post(path string, cookies []*http.Cookie, csrf string) req {
	return req{method: "POST", path: path, cookies: cookies, headers: map[string]string{"X-CSRF-Token": csrf}}
}

// Criterion 1: a button runs ctl and the answer says it worked.
func TestComponentButtonRunsCtl(t *testing.T) {
	f := newFakeCtl(t)
	e := setup(t, withCtl(f))
	cookies, csrf := e.login()

	w := e.do(post("/api/components/suricata/restart", cookies, csrf))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"ok":true`) {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if !f.called(t, "restart suricata") {
		t.Errorf("ctl calls: %q", f.calls(t))
	}

	w = e.do(post("/api/suricata/reload", cookies, csrf))
	if w.Code != 200 || !f.called(t, "reload suricata") {
		t.Errorf("reload: %d, calls %q", w.Code, f.calls(t))
	}
}

// Criterion 2.
func TestStoppingThePanelNeedsItsOwnConfirmation(t *testing.T) {
	f := newFakeCtl(t)
	e := setup(t, withCtl(f))
	cookies, csrf := e.login()

	for _, action := range []string{"stop", "restart"} {
		w := e.do(post("/api/components/panel/"+action, cookies, csrf))
		var body struct {
			Error           string
			ConfirmRequired bool `json:"confirm_required"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &body)
		if w.Code != http.StatusConflict || !body.ConfirmRequired || body.Error == "" {
			t.Errorf("%s without confirmation: %d %s", action, w.Code, w.Body)
		}
	}
	if n := f.callsStarting(t, "stop panel") + f.callsStarting(t, "restart panel"); n != 0 {
		t.Fatalf("ctl ran without confirmation: %q", f.calls(t))
	}

	w := e.do(post("/api/components/panel/stop?confirm=yes", cookies, csrf))
	if w.Code != http.StatusAccepted || !strings.Contains(w.Body.String(), `"detached":true`) {
		t.Fatalf("confirmed stop: %d %s", w.Code, w.Body)
	}
	waitFor(t, "the confirmed stop to reach ctl", func() bool { return f.called(t, "stop panel") })

	// Another component needs no second confirmation.
	if w := e.do(post("/api/components/ntopng/stop", cookies, csrf)); w.Code != 200 {
		t.Errorf("ntopng stop: %d %s", w.Code, w.Body)
	}
}

// Criterion 5.
func TestActionOnMissingComponentIs404WithText(t *testing.T) {
	f := newFakeCtl(t)
	e := setup(t, withCtl(f))
	cookies, csrf := e.login()

	for path, want := range map[string]string{
		"/api/components/nosuch/stop": "unknown component",
		"/api/components/redis/start": "not installed",
	} {
		w := e.do(post(path, cookies, csrf))
		if w.Code != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", path, w.Code)
			continue
		}
		if text := errorText(t, w); !strings.Contains(text, want) {
			t.Errorf("%s: text %q lacks %q", path, text, want)
		}
	}

	// Paths that cannot name a component never reach ctl.
	before := len(f.calls(t))
	for _, path := range []string{
		"/api/components/suricata/explode",
		"/api/components/Suricata/stop",
		"/api/components/suri.cata/stop",
		"/api/components/-x/stop",
	} {
		if w := e.do(post(path, cookies, csrf)); w.Code != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", path, w.Code)
		}
	}
	if after := len(f.calls(t)); after != before {
		t.Errorf("ctl was called for a malformed path: %q", f.calls(t)[before:])
	}
}

// Criterion 3.
func TestLogsLinesLimit(t *testing.T) {
	f := newFakeCtl(t)
	e := setup(t, withCtl(f))
	cookies, _ := e.login()

	for _, lines := range []string{"5000", "1001", "0", "-3", "abc", "1.5"} {
		w := e.do(req{method: "GET", path: "/api/logs/suricata?lines=" + lines, cookies: cookies})
		if w.Code != http.StatusBadRequest {
			t.Errorf("lines=%s: %d, want 400", lines, w.Code)
		}
	}
	if n := f.callsStarting(t, "logs"); n != 0 {
		t.Fatalf("ctl was called for a rejected limit: %q", f.calls(t))
	}

	w := e.do(req{method: "GET", path: "/api/logs/suricata?lines=1000", cookies: cookies})
	if w.Code != 200 || !f.called(t, "logs suricata -n 1000") {
		t.Fatalf("lines=1000: %d, calls %q", w.Code, f.calls(t))
	}
	var body struct {
		ID    string
		Lines []string
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.ID != "suricata" || len(body.Lines) != 2 || body.Lines[1] != "line two" {
		t.Errorf("body: %s", w.Body)
	}

	if w := e.do(req{method: "GET", path: "/api/logs/suricata", cookies: cookies}); w.Code != 200 || !f.called(t, "logs suricata -n 200") {
		t.Errorf("default lines: %d, calls %q", w.Code, f.calls(t))
	}
	if w := e.do(req{method: "GET", path: "/api/logs/nosuch", cookies: cookies}); w.Code != http.StatusNotFound {
		t.Errorf("unknown component: %d, want 404", w.Code)
	}
}

// liveServer serves the panel on a real socket (a stream needs one) in
// localhost mode, and returns a client that is already logged in.
func liveServer(t *testing.T, f *fakeCtl) (*httptest.Server, *http.Client) {
	t.Helper()
	policy, err := auth.NewPolicy("localhost", "")
	if err != nil {
		t.Fatal(err)
	}
	e := setup(t, withCtl(f), func(c *Config, _ string) { c.Policy = policy })
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

func openStream(t *testing.T, ctx context.Context, ts *httptest.Server, client *http.Client, id string) *http.Response {
	t.Helper()
	hr, _ := http.NewRequestWithContext(ctx, "GET", ts.URL+"/api/logs/"+id+"/stream", nil)
	resp, err := client.Do(hr)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func readEvent(t *testing.T, r *bufio.Reader) string {
	t.Helper()
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatalf("reading the stream: %v", err)
	}
	return strings.TrimRight(line, "\n")
}

func processGone(pid int) bool {
	return syscall.Kill(pid, 0) == syscall.ESRCH
}

func readPIDs(t *testing.T, f *fakeCtl) []int {
	data, err := os.ReadFile(f.pidFile)
	if err != nil {
		return nil
	}
	var pids []int
	for _, s := range strings.Fields(string(data)) {
		pid, err := strconv.Atoi(s)
		if err != nil {
			t.Fatal(err)
		}
		pids = append(pids, pid)
	}
	return pids
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// Criterion 4: the process behind a log stream is gone once the client is.
// The fake ctl, like the real one, ends only when its stdin closes and
// ignores everything else, so this proves the panel closes it. The wait is
// shorter than the grace after which the panel would kill it anyway.
func TestLogStreamEndsCtlWhenClientLeaves(t *testing.T) {
	f := newFakeCtl(t)
	ts, client := liveServer(t, f)

	ctx, cancel := context.WithCancel(context.Background())
	resp := openStream(t, ctx, ts, client, "suricata")
	defer resp.Body.Close()
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/event-stream") {
		t.Fatalf("%d %q", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	br := bufio.NewReader(resp.Body)
	if got := readEvent(t, br); got != "data: first line" {
		t.Fatalf("first event line: %q", got)
	}

	pids := readPIDs(t, f)
	if len(pids) != 1 || processGone(pids[0]) {
		t.Fatalf("ctl should be running while the stream is open: %v", pids)
	}
	if !f.called(t, "logs suricata -n 50 --until-stdin-closed") {
		t.Errorf("ctl calls: %q", f.calls(t))
	}

	cancel() // the browser closes the page
	waitFor(t, "ctl to exit after the client left", func() bool { return processGone(pids[0]) })
}

func TestLogStreamOfUnknownComponentIsAPlainError(t *testing.T) {
	f := newFakeCtl(t)
	ts, client := liveServer(t, f)

	resp := openStream(t, context.Background(), ts, client, "nosuch")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("%d, want 404", resp.StatusCode)
	}
	var body struct{ Error string }
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body.Error, "unknown component") {
		t.Errorf("error text: %q", body.Error)
	}
}

// Each stream holds a sudo and a journalctl; the panel has 64 MB.
func TestOnlyAFewLogStreamsAtOnce(t *testing.T) {
	f := newFakeCtl(t)
	ts, client := liveServer(t, f)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	for i := 0; i < maxStreams; i++ {
		resp := openStream(t, ctx, ts, client, "suricata")
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("stream %d: %d", i+1, resp.StatusCode)
		}
		readEvent(t, bufio.NewReader(resp.Body))
	}
	resp := openStream(t, ctx, ts, client, "suricata")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("one stream too many: %d, want 429", resp.StatusCode)
	}

	cancel()
	pids := readPIDs(t, f)
	waitFor(t, "every ctl to exit", func() bool {
		for _, pid := range pids {
			if !processGone(pid) {
				return false
			}
		}
		return true
	})
}
