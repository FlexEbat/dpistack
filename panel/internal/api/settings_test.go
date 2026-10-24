package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const settingsCtlScript = `#!/bin/sh
echo "$*" >> '@LOG@'
dir='@DIR@'
[ "$1" = settings ] || exit 0
case "$2" in
list) cat "$dir/list.json" ;;
check)
  cat > "$dir/stdin.check"
  cat "$dir/check.json"
  exit $(cat "$dir/check.rc" 2>/dev/null || echo 0) ;;
set)
  cat > "$dir/stdin.set"
  if [ -f "$dir/set.rc" ]; then cat "$dir/set.out"; exit $(cat "$dir/set.rc"); fi
  echo "applied" ;;
secret) cat > "$dir/stdin.secret"; echo "secret written" ;;
job) echo '{"state":"inactive","result":"","log":["a","b"]}' ;;
esac
`

func settingsCtl(t *testing.T) *opsCtl {
	t.Helper()
	c := newOpsCtl(t)
	script := strings.NewReplacer("@LOG@", c.log, "@DIR@", c.dir).Replace(settingsCtlScript)
	if err := os.WriteFile(c.runner.Path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c.write(t, "list.json", `{"keys":[{"key":"STATS_INTERVAL_SEC","type":"int","value":"30"}]}`)
	c.write(t, "check.json", `{"ok":true,"weight":"light","changed":["STATS_INTERVAL_SEC"],"errors":[],"warnings":[]}`)
	return c
}

func (c *opsCtl) read(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(c.dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func jsonMap(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("not JSON: %q: %v", body, err)
	}
	return m
}

func TestSettingsNeedALogin(t *testing.T) {
	e := setup(t, withOpsCtl(settingsCtl(t)))
	for _, p := range []string{"GET /api/settings", "POST /api/settings/check", "POST /api/settings/apply", "GET /api/settings/job"} {
		f := strings.Fields(p)
		if w := send(e, f[0], f[1], `{"values":{"A_B":"1"}}`, nil, ""); w.Code != http.StatusUnauthorized {
			t.Errorf("%s without a session: %d", p, w.Code)
		}
	}
}

func TestSettingsListIsCtlsJSON(t *testing.T) {
	c := settingsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "GET", "/api/settings", "", cookies, csrf)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"STATS_INTERVAL_SEC"`) {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if !c.called(t, "settings list --json") {
		t.Errorf("calls: %q", c.calls(t))
	}
}

func TestSettingsCheckSendsPairsOnStdinSorted(t *testing.T) {
	c := settingsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/settings/check", `{"values":{"STATS_INTERVAL_SEC":"45","BPF_FILTER":"not (host 10.0.0.1 && port 22)"}}`, cookies, csrf)
	if w.Code != 200 || jsonMap(t, w.Body.Bytes())["weight"] != "light" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if got := c.read(t, "stdin.check"); got != "BPF_FILTER=not (host 10.0.0.1 && port 22)\nSTATS_INTERVAL_SEC=45\n" {
		t.Errorf("stdin: %q", got)
	}
	// the values are not on the command line
	if !c.called(t, "settings check") {
		t.Errorf("calls: %q", c.calls(t))
	}
}

func TestSettingsCheckFailureIsAnAnswer(t *testing.T) {
	c := settingsCtl(t)
	c.write(t, "check.json", `{"ok":false,"weight":"light","changed":["STATS_INTERVAL_SEC"],"errors":["STATS_INTERVAL_SEC: out of range 5..300"],"warnings":[]}`)
	c.write(t, "check.rc", "3")
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/settings/check", `{"values":{"STATS_INTERVAL_SEC":"9999"}}`, cookies, csrf)
	m := jsonMap(t, w.Body.Bytes())
	if w.Code != 200 || m["ok"] != false || !strings.Contains(w.Body.String(), "out of range") {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}

func TestSettingsApplyLightAndHeavy(t *testing.T) {
	c := settingsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	w := send(e, "POST", "/api/settings/apply", `{"values":{"STATS_INTERVAL_SEC":"45"}}`, cookies, csrf)
	if w.Code != 200 || jsonMap(t, w.Body.Bytes())["ok"] != true {
		t.Fatalf("light: %d %s", w.Code, w.Body)
	}
	if !c.called(t, "settings set --apply") {
		t.Errorf("calls: %q", c.calls(t))
	}

	c.write(t, "check.json", `{"ok":true,"weight":"heavy","changed":["SURICATA_SOURCE"],"errors":[],"warnings":[]}`)
	w = send(e, "POST", "/api/settings/apply", `{"values":{"SURICATA_SOURCE":"distro"},"confirm_access":true}`, cookies, csrf)
	if w.Code != http.StatusAccepted {
		t.Fatalf("heavy: %d %s", w.Code, w.Body)
	}
	if !c.called(t, "settings set --apply-heavy --confirm-access") {
		t.Errorf("calls: %q", c.calls(t))
	}
}

func TestSettingsApplyStopsOnAFailedCheckAndWritesNothing(t *testing.T) {
	c := settingsCtl(t)
	c.write(t, "check.json", `{"ok":false,"weight":"light","changed":["STATS_INTERVAL_SEC"],"errors":["bad"],"warnings":[]}`)
	c.write(t, "check.rc", "3")
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/settings/apply", `{"values":{"STATS_INTERVAL_SEC":"9999"}}`, cookies, csrf)
	if w.Code != http.StatusUnprocessableEntity || !strings.Contains(w.Body.String(), "bad") {
		t.Errorf("%d %s", w.Code, w.Body)
	}
	for _, call := range c.calls(t) {
		if strings.HasPrefix(call, "settings set") {
			t.Errorf("set was called after a failed check: %q", c.calls(t))
		}
	}
}

func TestSettingsApplyBusyPortIsAnAnswerWithAFreePort(t *testing.T) {
	c := settingsCtl(t)
	c.write(t, "set.out", "port 9900 (PANEL_PORT) is already busy: nginx; free: 9901")
	c.write(t, "set.rc", "3")
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/settings/apply", `{"values":{"PANEL_PORT":"9900"}}`, cookies, csrf)
	if w.Code != http.StatusUnprocessableEntity || !strings.Contains(w.Body.String(), "free: 9901") {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}

func TestSettingsApplyNoChange(t *testing.T) {
	c := settingsCtl(t)
	c.write(t, "check.json", `{"ok":true,"weight":"light","changed":[],"errors":[],"warnings":[]}`)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/settings/apply", `{"values":{"STATS_INTERVAL_SEC":"30"}}`, cookies, csrf)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "no changes") {
		t.Errorf("%d %s", w.Code, w.Body)
	}
	for _, call := range c.calls(t) {
		if strings.HasPrefix(call, "settings set") {
			t.Errorf("set was called for no change: %q", c.calls(t))
		}
	}
}

func TestSettingsRefuseWhatCannotBeALine(t *testing.T) {
	c := settingsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	for name, body := range map[string]string{
		"lower-case key": `{"values":{"stats":"1"}}`,
		"newline":        `{"values":{"BPF_FILTER":"a\nPANEL_PORT=1"}}`,
		"empty":          `{"values":{}}`,
		"not JSON":       `values`,
		"too long":       `{"values":{"BPF_FILTER":"` + strings.Repeat("a", 2000) + `"}}`,
	} {
		if w := send(e, "POST", "/api/settings/apply", body, cookies, csrf); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	if len(c.calls(t)) != 0 {
		t.Errorf("ctl was called: %q", c.calls(t))
	}
}

func TestSettingsSecretGoesOnStdinAndIsNeverEchoed(t *testing.T) {
	c := settingsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	w := send(e, "PUT", "/api/settings/secret/ALERT_TG_TOKEN", `{"value":"123456:TOPSECRET"}`, cookies, csrf)
	if w.Code != 200 || strings.Contains(w.Body.String(), "TOPSECRET") {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if c.read(t, "stdin.secret") != "123456:TOPSECRET\n" {
		t.Errorf("stdin: %q", c.read(t, "stdin.secret"))
	}
	for _, call := range c.calls(t) {
		if strings.Contains(call, "TOPSECRET") {
			t.Errorf("the secret is on the command line: %q", call)
		}
	}
	if w := send(e, "PUT", "/api/settings/secret/bad-key", `{"value":"x"}`, cookies, csrf); w.Code != http.StatusBadRequest {
		t.Errorf("bad key: %d", w.Code)
	}
}

func TestSettingsJobPassesThrough(t *testing.T) {
	e := setup(t, withOpsCtl(settingsCtl(t)))
	cookies, csrf := e.login()
	w := send(e, "GET", "/api/settings/job", "", cookies, csrf)
	if w.Code != 200 || jsonMap(t, w.Body.Bytes())["state"] != "inactive" {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}
