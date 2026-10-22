package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// configCtl stands in for dpistack's config commands. Content with BAD
// in it fails the check, like a bad suricata.yaml fails `suricata -T`; a
// dpistack.conf with HEAVY in it is a change reconfigure refuses.
type configCtl struct {
	runner *ctl.Runner
	dir    string
	log    string
}

func newConfigCtl(t *testing.T) *configCtl {
	t.Helper()
	dir := t.TempDir()
	c := &configCtl{dir: filepath.Join(dir, "files"), log: filepath.Join(dir, "calls")}
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, text := range map[string]string{
		"suricata.yaml": "old: yaml\n",
		"dpistack.conf": "IFACES=eth0\n",
	} {
		if err := os.WriteFile(filepath.Join(c.dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	script := `#!/bin/sh
echo "$*" >> '` + c.log + `'
dir='` + c.dir + `'
name="$2"
case "$1" in
config-read) cat "$dir/$name" ;;
config-write)
  cat > "$dir/.staged"
  if grep -q BAD "$dir/.staged"; then
    echo "validator: ошибка в строке 3"
    echo "dpistack: $name: проверка не пройдена, файл не изменён" >&2
    exit 3
  fi
  if [ "$3" = "--check" ]; then echo "проверка пройдена: suricata -T успешно"; exit 0; fi
  cp "$dir/$name" "$dir/$name.bak"
  cp "$dir/.staged" "$dir/$name"
  if [ "$3" = "--apply" ]; then
    if [ "$name" = dpistack.conf ] && grep -q HEAVY "$dir/.staged"; then
      echo "dpistack: тяжёлое изменение (SURICATA_SOURCE): выполните install.sh reconfigure" >&2
      exit 3
    fi
    echo "применено: $name"
  fi
  echo "сохранено" ;;
config-revert)
  if [ -f "$dir/$name.bak" ]; then cp "$dir/$name.bak" "$dir/$name"; echo "восстановлено из бэкапа"
  else echo "dpistack: нет бэкапа для $name" >&2; exit 1; fi ;;
esac
`
	path := filepath.Join(dir, "ctl")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c.runner = &ctl.Runner{Path: path}
	return c
}

func (c *configCtl) calls(t *testing.T) []string {
	data, err := os.ReadFile(c.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func (c *configCtl) called(t *testing.T, want string) bool {
	for _, call := range c.calls(t) {
		if call == want {
			return true
		}
	}
	return false
}

func withConfigCtl(c *configCtl) option {
	return func(cfg *Config, _ string) { cfg.Ctl = c.runner }
}

func send(e *env, method, path, body string, cookies []*http.Cookie, csrf string) *httptest.ResponseRecorder {
	return e.do(req{method: method, path: path, body: body, cookies: cookies,
		headers: map[string]string{"X-CSRF-Token": csrf, "Content-Type": "text/plain"}})
}

type configAnswer struct {
	Error   string
	Output  string
	Ok      bool
	Name    string
	Content string
}

func decode(t *testing.T, w *httptest.ResponseRecorder) configAnswer {
	t.Helper()
	var a configAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &a); err != nil {
		t.Fatalf("not JSON: %q", w.Body)
	}
	return a
}

// Criterion 1: "Проверить" shows the checker's words and saves nothing; a
// save that fails the check leaves the file as it was.
func TestCheckAndSaveOfAFileThatFailsTheCheck(t *testing.T) {
	c := newConfigCtl(t)
	e := setup(t, withConfigCtl(c))
	cookies, csrf := e.login()

	w := send(e, "POST", "/api/config/suricata.yaml/check", "new: yaml\n", cookies, csrf)
	if got := decode(t, w); w.Code != 200 || !strings.Contains(got.Output, "проверка пройдена") {
		t.Fatalf("good check: %d %s", w.Code, w.Body)
	}
	if !c.called(t, "config-write suricata.yaml --check") {
		t.Fatalf("a check must ask ctl for --check, calls: %q", c.calls(t))
	}

	for _, path := range []string{"/api/config/suricata.yaml/check", "/api/config/suricata.yaml"} {
		method := "POST"
		if !strings.HasSuffix(path, "/check") {
			method = "PUT"
		}
		w := send(e, method, path, "BAD: yaml\n", cookies, csrf)
		got := decode(t, w)
		if w.Code != http.StatusUnprocessableEntity {
			t.Errorf("%s %s: %d, want 422", method, path, w.Code)
		}
		if !strings.Contains(got.Output, "ошибка в строке 3") || !strings.Contains(got.Error, "проверка не пройдена") {
			t.Errorf("%s %s: the checker's words are lost: %s", method, path, w.Body)
		}
	}

	// The body must reach ctl's stdin unchanged: what was saved is what is read.
	text := "new: yaml\nkey: \"значение\"\n"
	w = send(e, "PUT", "/api/config/suricata.yaml", text, cookies, csrf)
	if w.Code != 200 {
		t.Fatalf("good save: %d %s", w.Code, w.Body)
	}
	w = e.do(req{method: "GET", path: "/api/config/suricata.yaml", cookies: cookies})
	if got := decode(t, w); w.Code != 200 || got.Name != "suricata.yaml" || got.Content != text {
		t.Errorf("read back: %d %s", w.Code, w.Body)
	}
}

// Criterion 2.
func TestSaveAndApply(t *testing.T) {
	c := newConfigCtl(t)
	e := setup(t, withConfigCtl(c))
	cookies, csrf := e.login()

	w := send(e, "PUT", "/api/config/suricata.yaml?apply=1", "new: yaml\n", cookies, csrf)
	if got := decode(t, w); w.Code != 200 || !strings.Contains(got.Output, "применено") {
		t.Fatalf("apply: %d %s", w.Code, w.Body)
	}
	if !c.called(t, "config-write suricata.yaml --apply") {
		t.Errorf("ctl calls: %q", c.calls(t))
	}

	// A save without apply must not apply.
	send(e, "PUT", "/api/config/suricata.yaml?apply=0", "newer: yaml\n", cookies, csrf)
	if !c.called(t, "config-write suricata.yaml") {
		t.Errorf("ctl calls: %q", c.calls(t))
	}

	// A heavy dpistack.conf change is shown as a refusal with ctl's text.
	w = send(e, "PUT", "/api/config/dpistack.conf?apply=1", "SURICATA_SOURCE=HEAVY\n", cookies, csrf)
	got := decode(t, w)
	if w.Code != http.StatusUnprocessableEntity || !strings.Contains(got.Error, "install.sh reconfigure") {
		t.Fatalf("heavy change: %d %s", w.Code, w.Body)
	}

	before := len(c.calls(t))
	if w := send(e, "PUT", "/api/config/suricata.yaml?apply=2", "x\n", cookies, csrf); w.Code != http.StatusBadRequest {
		t.Errorf("apply=2: %d, want 400", w.Code)
	}
	if len(c.calls(t)) != before {
		t.Error("ctl was called for a malformed apply flag")
	}
}

// Criterion 3.
func TestRevertAsksCtlForTheBackup(t *testing.T) {
	c := newConfigCtl(t)
	e := setup(t, withConfigCtl(c))
	cookies, csrf := e.login()

	if w := send(e, "POST", "/api/config/suricata.yaml/revert", "", cookies, csrf); w.Code < 400 || !strings.Contains(decode(t, w).Error, "нет бэкапа") {
		t.Errorf("revert without a backup: %d %s", w.Code, w.Body)
	}

	send(e, "PUT", "/api/config/suricata.yaml", "new: yaml\n", cookies, csrf)
	w := send(e, "POST", "/api/config/suricata.yaml/revert", "", cookies, csrf)
	if got := decode(t, w); w.Code != 200 || !strings.Contains(got.Output, "восстановлено") {
		t.Fatalf("revert: %d %s", w.Code, w.Body)
	}
	if !c.called(t, "config-revert suricata.yaml") {
		t.Errorf("ctl calls: %q", c.calls(t))
	}
}

// Criterion 4.
func TestUnknownNamesAndHugeBodies(t *testing.T) {
	c := newConfigCtl(t)
	e := setup(t, withConfigCtl(c))
	cookies, csrf := e.login()

	for _, name := range []string{"etc-passwd", "suricata.yaml%2F..%2Fpasswd", "suricata.yaml.bak", "Suricata.yaml", "passwd"} {
		for _, r := range []struct{ method, suffix string }{
			{"GET", ""}, {"PUT", ""}, {"POST", "/check"}, {"POST", "/revert"},
		} {
			w := send(e, r.method, "/api/config/"+name+r.suffix, "x\n", cookies, csrf)
			if w.Code != http.StatusNotFound {
				t.Errorf("%s /api/config/%s%s: %d, want 404", r.method, name, r.suffix, w.Code)
			}
		}
	}
	if n := len(c.calls(t)); n != 0 {
		t.Fatalf("ctl was called for names outside the list: %q", c.calls(t))
	}

	big := strings.Repeat("a", 1<<20+1)
	if w := send(e, "PUT", "/api/config/suricata.yaml", big, cookies, csrf); w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("1 MiB + 1 byte: %d, want 413", w.Code)
	}
	if n := len(c.calls(t)); n != 0 {
		t.Fatalf("ctl was called for an oversized body: %q", c.calls(t))
	}
	exact := strings.Repeat("a", 1<<20)
	if w := send(e, "PUT", "/api/config/suricata.yaml", exact, cookies, csrf); w.Code != 200 {
		t.Errorf("exactly 1 MiB: %d, want 200", w.Code)
	}

	w := e.do(req{method: "GET", path: "/api/config", cookies: cookies})
	var list struct{ Names []string }
	if err := json.Unmarshal(w.Body.Bytes(), &list); err != nil || len(list.Names) != 9 || list.Names[0] != "dpistack.conf" {
		t.Errorf("name list: %d %s", w.Code, w.Body)
	}
}
