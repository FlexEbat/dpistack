package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// opsCtl stands in for the tests and iface commands of dpistack-ctl. Files in
// its directory steer it: <name>.status for a test, GARBAGE, HOLD (wait),
// FAIL (reconfigure fails), and ifaces and system for the interface lists.
type opsCtl struct {
	runner *ctl.Runner
	dir    string
	log    string
}

const opsCtlScript = `#!/bin/sh
echo "$*" >> '@LOG@'
dir='@DIR@'
one() {
  st=$(cat "$dir/$1.status" 2>/dev/null || echo pass)
  printf '{"name":"%s","status":"%s","detail":"detail of %s: причина","duration_ms":12}' "$1" "$st" "$1"
  [ "$st" = fail ] && echo 1 > "$dir/anyfail"
}
case "$1" in
test)
  [ -f "$dir/HOLD" ] && while [ -f "$dir/HOLD" ]; do sleep 0.05; done
  rm -f "$dir/anyfail"
  if [ -f "$dir/GARBAGE" ]; then echo "something else entirely"; exit 0; fi
  echo "progress noise"
  case "$2" in
  all) printf '['; one bittorrent; printf ','; one https; printf ']\n' ;;
  *) printf '['; one "$2"; printf ']\n' ;;
  esac
  [ -f "$dir/anyfail" ] && exit 1
  exit 0 ;;
iface)
  case "$2" in
  list) cat "$dir/ifaces" ;;
  add)
    grep -qx "$3" "$dir/system" || { echo "dpistack-ctl: интерфейса нет в системе: $3" >&2; exit 5; }
    grep -qx "$3" "$dir/ifaces" && { echo "уже в списке: $3"; exit 0; }
    [ -f "$dir/HOLD" ] && while [ -f "$dir/HOLD" ]; do sleep 0.05; done
    [ -f "$dir/FAIL" ] && { echo "dpistack-ctl: reconfigure не удался, dpistack.conf возвращён" >&2; exit 1; }
    echo "$3" >> "$dir/ifaces"; echo "interface $3 added" ;;
  remove)
    grep -qx "$3" "$dir/ifaces" || { echo "dpistack-ctl: интерфейса нет в IFACES: $3" >&2; exit 5; }
    [ "$(wc -l < "$dir/ifaces")" -gt 1 ] || { echo "dpistack-ctl: нельзя удалить последний интерфейс" >&2; exit 3; }
    grep -vx "$3" "$dir/ifaces" > "$dir/i.tmp"; mv "$dir/i.tmp" "$dir/ifaces"; echo "interface $3 removed" ;;
  esac ;;
mode)
  case "$2" in
  status)
    m=$(cat "$dir/mode" 2>/dev/null || echo ids)
    if [ -f "$dir/remaining" ]; then p=true; r=$(cat "$dir/remaining"); else p=false; r=0; fi
    printf '{"mode":"%s","method":"nfq","pending":%s,"remaining_sec":%s}\n' "$m" "$p" "$r" ;;
  ids) rm -f "$dir/remaining"; echo ids > "$dir/mode"; echo "режим ids" ;;
  ips)
    [ -f "$dir/HOLD" ] && while [ -f "$dir/HOLD" ]; do sleep 0.05; done
    [ -f "$dir/FAIL" ] && { echo "dpistack-ctl: mode ips: не найден iptables (нужен для цепочки DPISTACK)" >&2; exit 3; }
    t=120; [ "$3" = "--confirm-timeout" ] && t="$4"
    echo ips > "$dir/mode"; echo "$t" > "$dir/remaining"
    echo "режим ips включён; подтвердите командой mode-confirm в течение $t с, иначе вернётся ids" ;;
  esac ;;
mode-confirm)
  [ -f "$dir/remaining" ] || { echo "dpistack-ctl: mode-confirm: нечего подтверждать" >&2; exit 3; }
  rm -f "$dir/remaining"; echo "режим ips подтверждён" ;;
esac
`

func newOpsCtl(t *testing.T) *opsCtl {
	t.Helper()
	root := t.TempDir()
	c := &opsCtl{dir: filepath.Join(root, "files"), log: filepath.Join(root, "calls")}
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	c.write(t, "ifaces", "enp2s0\n")
	c.write(t, "system", "enp2s0\neth1\nbr0\n")
	script := strings.NewReplacer("@LOG@", c.log, "@DIR@", c.dir).Replace(opsCtlScript)
	path := filepath.Join(root, "ctl")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c.runner = &ctl.Runner{Path: path}
	return c
}

func (c *opsCtl) write(t *testing.T, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(c.dir, name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (c *opsCtl) calls(t *testing.T) []string {
	data, err := os.ReadFile(c.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func (c *opsCtl) called(t *testing.T, want string) bool {
	for _, call := range c.calls(t) {
		if call == want {
			return true
		}
	}
	return false
}

func withOpsCtl(c *opsCtl, extra ...option) option {
	return func(cfg *Config, dir string) {
		cfg.Ctl = c.runner
		for _, o := range extra {
			o(cfg, dir)
		}
	}
}

func withTestsFile(path string) option {
	return func(cfg *Config, _ string) { cfg.TestsFile = path }
}

type testsAnswer struct {
	Name       string
	Status     string
	Detail     string
	DurationMS int64 `json:"duration_ms"`
}

// Criterion 1: the buttons run `ctl test`, and each test comes back as a row
// with pass, fail or skip and its reason. A failed test is a result (200).
func TestTestsRunShowsEveryResultWithItsReason(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	run := func(which string) (int, []testsAnswer, string) {
		w := send(e, "POST", "/api/tests/"+which, "", cookies, csrf)
		var got []testsAnswer
		_ = json.Unmarshal(w.Body.Bytes(), &got)
		return w.Code, got, w.Body.String()
	}

	code, got, body := run("bittorrent")
	if code != 200 || len(got) != 1 || got[0].Name != "bittorrent" || got[0].Status != "pass" ||
		!strings.Contains(got[0].Detail, "причина") || got[0].DurationMS != 12 {
		t.Fatalf("bittorrent: %d %s", code, body)
	}
	if !c.called(t, "test bittorrent --json") {
		t.Errorf("ctl calls: %q", c.calls(t))
	}

	c.write(t, "https.status", "skip")
	if code, got, body := run("https"); code != 200 || len(got) != 1 || got[0].Status != "skip" {
		t.Fatalf("https skip: %d %s", code, body)
	}

	// `all` with one failing test: ctl exits 1, the panel still answers 200
	// with both rows, the failing one marked.
	c.write(t, "https.status", "fail")
	code, got, body = run("all")
	if code != 200 || len(got) != 2 || got[0].Status != "pass" || got[1].Name != "https" || got[1].Status != "fail" ||
		!strings.Contains(got[1].Detail, "причина") {
		t.Fatalf("all with a failure: %d %s", code, body)
	}

	for _, bad := range []string{"udp", "ALL", "bittorrent%20x", "..%2Fall"} {
		if code, _, _ := run(bad); code != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", bad, code)
		}
	}
}

func TestTestsRunSurvivesNoiseAndRefusesGarbage(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	// The fake prints a progress line before the array; the array is what counts.
	if w := send(e, "POST", "/api/tests/https", "", cookies, csrf); w.Code != 200 {
		t.Fatalf("noise before the array: %d %s", w.Code, w.Body)
	}
	c.write(t, "GARBAGE", "")
	if w := send(e, "POST", "/api/tests/https", "", cookies, csrf); w.Code != http.StatusInternalServerError {
		t.Errorf("no results at all: %d, want 500", w.Code)
	}
}

// One run at a time; while it runs, the last-result endpoint says so.
func TestSecondTestRunIs409AndLastSaysRunning(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	c.write(t, "HOLD", "")
	var wg sync.WaitGroup
	wg.Add(1)
	var first int
	go func() { defer wg.Done(); first = send(e, "POST", "/api/tests/all", "", cookies, csrf).Code }()

	deadline := time.Now().Add(5 * time.Second)
	for {
		w := e.do(req{method: "GET", path: "/api/tests/last", cookies: cookies})
		var last struct{ Running bool }
		_ = json.Unmarshal(w.Body.Bytes(), &last)
		if last.Running {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the run never showed as running")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if w := send(e, "POST", "/api/tests/bittorrent", "", cookies, csrf); w.Code != http.StatusConflict {
		t.Errorf("second run: %d, want 409", w.Code)
	}
	if err := os.Remove(filepath.Join(c.dir, "HOLD")); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if first != 200 {
		t.Errorf("first run: %d", first)
	}
	n := 0
	for _, call := range c.calls(t) {
		if strings.HasPrefix(call, "test ") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("ctl test ran %d times, want 1", n)
	}
	w := e.do(req{method: "GET", path: "/api/tests/last", cookies: cookies})
	var last struct{ Running bool }
	_ = json.Unmarshal(w.Body.Bytes(), &last)
	if last.Running {
		t.Error("running stays true after the run")
	}
}

// Criterion 2: the last result is read from tests-last.json, so it is there
// after the panel restarts; a missing or damaged file is an empty list.
func TestLastResultSurvivesARestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tests-last.json")
	content := `{"results":[
{"name":"bittorrent","status":"pass","detail":"сигнатура: ET P2P BitTorrent DHT ping request","duration_ms":812,"timestamp":"2026-10-08T12:00:00Z"},
{"name":"https","status":"fail","detail":"curl не прошёл","duration_ms":15000,"timestamp":"2026-10-08T12:01:00Z"}
]}`
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	type last struct {
		Results []struct {
			Name, Status, Detail, Timestamp string
			DurationMS                      int64 `json:"duration_ms"`
		}
		Running bool
	}
	read := func(e *env) last {
		cookies, _ := e.login()
		w := e.do(req{method: "GET", path: "/api/tests/last", cookies: cookies})
		var l last
		if err := json.Unmarshal(w.Body.Bytes(), &l); err != nil || w.Code != 200 {
			t.Fatalf("last: %d %s", w.Code, w.Body)
		}
		return l
	}

	before := read(setup(t, withTestsFile(path)))
	after := read(setup(t, withTestsFile(path))) // a new panel process, the same file
	for _, l := range []last{before, after} {
		if len(l.Results) != 2 || l.Results[0].Name != "bittorrent" || l.Results[1].Status != "fail" ||
			l.Results[1].Detail != "curl не прошёл" || l.Results[0].Timestamp != "2026-10-08T12:00:00Z" {
			t.Fatalf("last results: %+v", l)
		}
	}

	for name, file := range map[string]string{"missing": filepath.Join(t.TempDir(), "none.json"), "damaged": path + ".bad", "unset": ""} {
		if name == "damaged" {
			if err := os.WriteFile(file, []byte(`{"results":[{"name":`), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		l := read(setup(t, withTestsFile(file)))
		if l.Results == nil || len(l.Results) != 0 {
			t.Errorf("%s file: %+v, want an empty list", name, l.Results)
		}
	}
}

func TestTestsNeedASession(t *testing.T) {
	e := setup(t)
	for _, r := range []struct{ method, path string }{
		{"POST", "/api/tests/all"}, {"GET", "/api/tests/last"}, {"GET", "/api/alerts"},
		{"GET", "/api/iface"}, {"POST", "/api/iface/add"},
	} {
		if w := e.do(req{method: r.method, path: r.path}); w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s without a session: %d, want 401", r.method, r.path, w.Code)
		}
	}
}
