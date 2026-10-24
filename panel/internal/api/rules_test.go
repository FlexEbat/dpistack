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

// rulesCtl stands in for dpistack's rules commands, with state: the
// enabled sources, disable.conf and the ruleset live in files, and
// rules-update rebuilds the ruleset without the sids disable.conf names, as
// suricata-update does. A FAIL file makes the update fail and keep the old
// ruleset; a HOLD file makes it wait until the file is removed.
type rulesCtl struct {
	runner *ctl.Runner
	dir    string
	log    string
}

const rulesCtlScript = `#!/bin/sh
echo "$*" >> '@LOG@'
dir='@DIR@'
esc=$(printf '\033')
case "$1" in
rules-sources)
  case "$2" in
  list)
    if [ "$3" = "--enabled" ]; then
      echo "Enabled sources:"
      sed 's/^/  - /' "$dir/enabled"
      echo "From /etc/suricata/update.yaml:"
      echo "  - not-ours"
      exit 0
    fi
    printf '%s[1;36mName%s[0m: %s[1;35met/open%s[0m\n' "$esc" "$esc" "$esc" "$esc"
    echo "  Vendor: Proofpoint"
    echo "  Summary: Emerging Threats Open Ruleset"
    echo "  License: MIT"
    printf '%s[1;36mName%s[0m: %s[1;35mtgreen/hunting%s[0m\n' "$esc" "$esc" "$esc" "$esc"
    echo "  Vendor: tgreen"
    echo "  Summary: Threat hunting rules: all of them"
    echo "  License: GPLv3"
    ;;
  enable) grep -qx "$3" "$dir/enabled" || echo "$3" >> "$dir/enabled"; echo "source $3 enabled" ;;
  disable|remove) grep -vx "$3" "$dir/enabled" > "$dir/e.tmp"; mv "$dir/e.tmp" "$dir/enabled"; echo "source $3 removed" ;;
  add-url) echo "dpistack-custom-1a2b3c4d" >> "$dir/enabled"; echo "added dpistack-custom-1a2b3c4d" ;;
  esac ;;
rules-sid)
  if [ "$2" = disable ]; then echo "$3" >> "$dir/disable.conf"
  else grep -vx "$3" "$dir/disable.conf" > "$dir/d.tmp"; mv "$dir/d.tmp" "$dir/disable.conf"; fi
  echo "sid $3: $2" ;;
rules-group)
  if [ "$2" = enable ]; then echo "group:$3" >> "$dir/enable.conf"
  else grep -vx "group:$3" "$dir/enable.conf" > "$dir/g.tmp"; mv "$dir/g.tmp" "$dir/enable.conf"; fi
  echo "group $3: $2" ;;
rules-search)
  if [ "$2" = probe ]; then i=1; while [ $i -le 60 ]; do printf '%s\tprobe rule\n' "$((9000+i))"; i=$((i+1)); done; exit 0; fi
  if [ ! -f "$dir/suricata.rules" ]; then echo "dpistack: no rule set" >&2; exit 4; fi
  grep -i -- "$2" "$dir/suricata.rules" | awk -F'\t' '{print $1 "\t" $2}' ;;
rules-update)
  if [ -f "$dir/HOLD" ]; then while [ -f "$dir/HOLD" ]; do sleep 0.05; done; fi
  if [ -f "$dir/FAIL" ]; then
    echo "suricata-update: could not download et/open: connection timed out"
    echo "dpistack: rules-update failed, previous rule set restored" >&2
    exit 1
  fi
  : > "$dir/new.rules"
  while IFS="$(printf '\t')" read -r sid msg; do
    grep -qx "$sid" "$dir/disable.conf" 2>/dev/null || printf '%s\t%s\n' "$sid" "$msg" >> "$dir/new.rules"
  done < "$dir/all.rules"
  mv "$dir/new.rules" "$dir/suricata.rules"
  echo "Total rules loaded: $(wc -l < "$dir/suricata.rules")" ;;
esac
`

func newRulesCtl(t *testing.T) *rulesCtl {
	t.Helper()
	root := t.TempDir()
	c := &rulesCtl{dir: filepath.Join(root, "files"), log: filepath.Join(root, "calls")}
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	all := "2001219\tET SCAN Potential SSH Scan\n2010935\tET SCAN Suspicious inbound to MSSQL port 1433\n2100498\tGPL ATTACK_RESPONSE id check returned root\n"
	for name, text := range map[string]string{
		"all.rules":      all,
		"suricata.rules": all,
		"enabled":        "et/open\ndpistack-custom-1a2b3c4d\n",
		"disable.conf":   "",
		"enable.conf":    "",
	} {
		if err := os.WriteFile(filepath.Join(c.dir, name), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	script := strings.NewReplacer("@LOG@", c.log, "@DIR@", c.dir).Replace(rulesCtlScript)
	path := filepath.Join(root, "ctl")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c.runner = &ctl.Runner{Path: path}
	return c
}

func (c *rulesCtl) calls(t *testing.T) []string {
	data, err := os.ReadFile(c.log)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(data)), "\n")
}

func (c *rulesCtl) called(t *testing.T, want string) bool {
	for _, call := range c.calls(t) {
		if call == want {
			return true
		}
	}
	return false
}

func (c *rulesCtl) touch(t *testing.T, name string) {
	if err := os.WriteFile(filepath.Join(c.dir, name), nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

func (c *rulesCtl) read(t *testing.T, name string) string {
	data, err := os.ReadFile(filepath.Join(c.dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func withRulesCtl(c *rulesCtl) option {
	return func(cfg *Config, _ string) { cfg.Ctl = c.runner }
}

type sourcesAnswer struct {
	Sources []struct {
		Name, Vendor, Summary, License string
		Enabled, Custom                bool
	}
	LastUpdate *struct {
		Time, Error, Output string
		OK                  bool `json:"ok"`
	} `json:"last_update"`
	Updating bool
}

func getSources(t *testing.T, e *env, cookies []*http.Cookie) sourcesAnswer {
	t.Helper()
	w := e.do(req{method: "GET", path: "/api/rules/sources", cookies: cookies})
	if w.Code != 200 {
		t.Fatalf("GET sources: %d %s", w.Code, w.Body)
	}
	var a sourcesAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &a); err != nil {
		t.Fatalf("not JSON: %q", w.Body)
	}
	return a
}

// Criterion 1: sources are listed with their enabled state, colours from
// suricata-update are gone, and enabling, disabling, adding by URL and
// removing go through ctl.
func TestSourcesListAndChange(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, csrf := e.login()

	a := getSources(t, e, cookies)
	if len(a.Sources) != 3 {
		t.Fatalf("want 2 indexed + 1 custom source, got %+v", a.Sources)
	}
	et, hunt, custom := a.Sources[0], a.Sources[1], a.Sources[2]
	if et.Name != "et/open" || !et.Enabled || et.Vendor != "Proofpoint" || et.License != "MIT" {
		t.Errorf("et/open: %+v", et)
	}
	if hunt.Name != "tgreen/hunting" || hunt.Enabled || hunt.Summary != "Threat hunting rules: all of them" {
		t.Errorf("tgreen/hunting (a colon inside the summary must survive): %+v", hunt)
	}
	if custom.Name != "dpistack-custom-1a2b3c4d" || !custom.Enabled || !custom.Custom {
		t.Errorf("custom source: %+v", custom)
	}
	if strings.Contains(et.Name+hunt.Name, "\x1b") {
		t.Error("colour codes reached the screen")
	}
	for _, s := range a.Sources {
		if s.Name == "not-ours" {
			t.Error("a source from another config file was listed as enabled")
		}
	}

	post := func(body string) *httpResult { return doJSON(e, "POST", "/api/rules/sources", body, cookies, csrf) }
	if r := post(`{"action":"enable","name":"tgreen/hunting"}`); r.code != 200 {
		t.Fatalf("enable: %d %s", r.code, r.body)
	}
	if !getSources(t, e, cookies).Sources[1].Enabled {
		t.Error("tgreen/hunting is not enabled after enable")
	}
	if r := post(`{"action":"disable","name":"tgreen/hunting"}`); r.code != 200 {
		t.Fatalf("disable: %d %s", r.code, r.body)
	}
	if getSources(t, e, cookies).Sources[1].Enabled {
		t.Error("tgreen/hunting is still enabled after disable")
	}
	if r := post(`{"action":"add-url","url":"https://example.org/rules/my.tar.gz"}`); r.code != 200 {
		t.Fatalf("add-url: %d %s", r.code, r.body)
	}
	if !c.called(t, "rules-sources add-url https://example.org/rules/my.tar.gz") {
		t.Errorf("ctl calls: %q", c.calls(t))
	}
	if r := post(`{"action":"remove","name":"dpistack-custom-1a2b3c4d"}`); r.code != 200 {
		t.Fatalf("remove: %d %s", r.code, r.body)
	}
}

type httpResult struct {
	code int
	body string
}

func doJSON(e *env, method, path, body string, cookies []*http.Cookie, csrf string) *httpResult {
	w := send(e, method, path, body, cookies, csrf)
	return &httpResult{code: w.Code, body: w.Body.String()}
}

// A value ctl would refuse never reaches it: the screen gets a sentence.
func TestRulesValuesAreCheckedBeforeCtl(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, csrf := e.login()

	bad := []struct{ method, path, body string }{
		{"POST", "/api/rules/sources", `{"action":"enable","name":"a b"}`},
		{"POST", "/api/rules/sources", `{"action":"enable","name":"x;rm -rf /"}`},
		{"POST", "/api/rules/sources", `{"action":"enable","name":""}`},
		{"POST", "/api/rules/sources", `{"action":"purge","name":"et/open"}`},
		{"POST", "/api/rules/sources", `{"action":"add-url","url":"ftp://example.org/x"}`},
		{"POST", "/api/rules/sources", `{"action":"add-url","url":"https://example.org/x?token=1"}`},
		{"POST", "/api/rules/sources", `{"action":"add-url","url":"https://example.org/%41"}`},
		{"POST", "/api/rules/sources", `not json`},
		{"GET", "/api/rules/search?q=", ""},
		{"GET", "/api/rules/search?q=%22quoted%22", ""},
		{"GET", "/api/rules/search?q=" + strings.Repeat("a", 101), ""},
		{"GET", "/api/rules/search?q=%D0%BF%D1%80%D0%B0%D0%B2%D0%B8%D0%BB%D0%BE", ""},
	}
	for _, b := range bad {
		if r := doJSON(e, b.method, b.path, b.body, cookies, csrf); r.code != http.StatusBadRequest {
			t.Errorf("%s %s %s: %d, want 400", b.method, b.path, b.body, r.code)
		}
	}
	notFound := []string{
		"/api/rules/sid/abc/disable", "/api/rules/sid/12345678901/disable", "/api/rules/sid/1/purge",
		"/api/rules/groups/a%2Fb/enable", "/api/rules/groups/x%20y/enable", "/api/rules/groups/ok.rules/purge",
	}
	for _, p := range notFound {
		if r := doJSON(e, "POST", p, "", cookies, csrf); r.code != http.StatusNotFound {
			t.Errorf("POST %s: %d, want 404", p, r.code)
		}
	}
	if n := len(c.calls(t)); n != 0 {
		t.Fatalf("ctl was called for refused values: %q", c.calls(t))
	}
}

// Criterion 2: a group is enabled and disabled through ctl.
func TestGroupToggle(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, csrf := e.login()

	if r := doJSON(e, "POST", "/api/rules/groups/emerging-p2p.rules/enable", "", cookies, csrf); r.code != 200 {
		t.Fatalf("enable group: %d %s", r.code, r.body)
	}
	if !strings.Contains(c.read(t, "enable.conf"), "group:emerging-p2p.rules") {
		t.Error("the group is not in enable.conf")
	}
	if r := doJSON(e, "POST", "/api/rules/groups/emerging-p2p.rules/disable", "", cookies, csrf); r.code != 200 {
		t.Fatalf("disable group: %d %s", r.code, r.body)
	}
	if strings.Contains(c.read(t, "enable.conf"), "emerging-p2p") {
		t.Error("the group is still in enable.conf")
	}
}

// Criterion 3: a sid disabled from the screen lands in disable.conf and,
// after an update, the rule is no longer in the ruleset. Enabling brings it
// back.
func TestDisabledSIDIsGoneAfterUpdate(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, csrf := e.login()

	if r := doJSON(e, "POST", "/api/rules/sid/2001219/disable", "", cookies, csrf); r.code != 200 {
		t.Fatalf("disable sid: %d %s", r.code, r.body)
	}
	if !strings.Contains(c.read(t, "disable.conf"), "2001219") {
		t.Fatal("the sid is not in disable.conf")
	}
	if r := doJSON(e, "POST", "/api/rules/update", "", cookies, csrf); r.code != 200 {
		t.Fatalf("update: %d %s", r.code, r.body)
	}
	search := func(q string) []ctl.Rule {
		w := e.do(req{method: "GET", path: "/api/rules/search?q=" + q, cookies: cookies})
		var got struct{ Results []ctl.Rule }
		if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil || w.Code != 200 {
			t.Fatalf("search %q: %d %s", q, w.Code, w.Body)
		}
		return got.Results
	}
	if got := search("2001219"); len(got) != 0 {
		t.Errorf("a disabled rule is still loaded: %+v", got)
	}
	if r := doJSON(e, "POST", "/api/rules/sid/2001219/enable", "", cookies, csrf); r.code != 200 {
		t.Fatalf("enable sid: %d %s", r.code, r.body)
	}
	doJSON(e, "POST", "/api/rules/update", "", cookies, csrf)
	if got := search("2001219"); len(got) != 1 {
		t.Errorf("an enabled rule did not come back: %+v", got)
	}
}

// Criterion 4: search by sid and by text; the list stops at 50 even if ctl
// says more; a missing ruleset is a readable 409.
func TestSearch(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, _ := e.login()

	type answer struct {
		Results   []ctl.Rule
		Truncated bool
		Error     string
	}
	get := func(q string) (int, answer) {
		w := e.do(req{method: "GET", path: "/api/rules/search?q=" + q, cookies: cookies})
		var a answer
		_ = json.Unmarshal(w.Body.Bytes(), &a)
		return w.Code, a
	}

	if code, a := get("2010935"); code != 200 || len(a.Results) != 1 || a.Results[0].SID != "2010935" ||
		!strings.Contains(a.Results[0].Msg, "MSSQL") || a.Truncated {
		t.Errorf("by sid: %d %+v", code, a)
	}
	if code, a := get("SCAN"); code != 200 || len(a.Results) != 2 {
		t.Errorf("by text: %d %+v", code, a)
	}
	if code, a := get("nothing-like-this"); code != 200 || a.Results == nil || len(a.Results) != 0 {
		t.Errorf("no hits must be an empty list, not null: %d %+v", code, a)
	}
	if code, a := get("probe"); code != 200 || len(a.Results) != ctl.MaxSearchResults || !a.Truncated {
		t.Errorf("cap: %d results=%d truncated=%v", code, len(a.Results), a.Truncated)
	}

	if err := os.Remove(filepath.Join(c.dir, "suricata.rules")); err != nil {
		t.Fatal(err)
	}
	if code, a := get("SCAN"); code != http.StatusConflict || !strings.Contains(a.Error, "no rule set") {
		t.Errorf("no ruleset: %d %+v", code, a)
	}
}

// Criterion 5: the button shows the result and the time of the update; a
// failure shows why and the old ruleset stays; the record is kept either way.
func TestUpdateShowsResultTimeAndFailureReason(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, csrf := e.login()

	if a := getSources(t, e, cookies); a.LastUpdate != nil {
		t.Fatalf("an update that never ran has a record: %+v", a.LastUpdate)
	}

	w := send(e, "POST", "/api/rules/update", "", cookies, csrf)
	var ok struct {
		Ok         bool
		Output     string
		LastUpdate struct{ Time string } `json:"last_update"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &ok); err != nil || w.Code != 200 || !ok.Ok ||
		!strings.Contains(ok.Output, "Total rules loaded: 3") {
		t.Fatalf("update: %d %s", w.Code, w.Body)
	}
	want := e.now.UTC().Format(time.RFC3339)
	if ok.LastUpdate.Time != want {
		t.Errorf("time %q, want %q", ok.LastUpdate.Time, want)
	}
	if a := getSources(t, e, cookies); a.LastUpdate == nil || !a.LastUpdate.OK || a.LastUpdate.Time != want {
		t.Errorf("the screen cannot see the last update: %+v", a.LastUpdate)
	}

	// A failed update: the reason from stdout reaches the screen, the ruleset
	// is as before, and the failure replaces the record.
	before := c.read(t, "suricata.rules")
	e.now = e.now.Add(time.Hour)
	c.touch(t, "FAIL")
	w = send(e, "POST", "/api/rules/update", "", cookies, csrf)
	var bad struct{ Error, Output string }
	if err := json.Unmarshal(w.Body.Bytes(), &bad); err != nil || w.Code != http.StatusInternalServerError {
		t.Fatalf("failed update: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(bad.Output, "connection timed out") || !strings.Contains(bad.Error, "previous rule set restored") {
		t.Errorf("the reason is lost: %s", w.Body)
	}
	if c.read(t, "suricata.rules") != before {
		t.Error("a failed update changed the ruleset")
	}
	a := getSources(t, e, cookies)
	if a.LastUpdate == nil || a.LastUpdate.OK || !strings.Contains(a.LastUpdate.Output, "connection timed out") ||
		a.LastUpdate.Time != e.now.UTC().Format(time.RFC3339) {
		t.Errorf("the failure is not recorded: %+v", a.LastUpdate)
	}
	if a.Updating {
		t.Error("updating stays true after a failure")
	}
}

// One update at a time: a second press while one runs is a 409 and does not
// start another ctl.
func TestSecondUpdateWhileOneRunsIs409(t *testing.T) {
	c := newRulesCtl(t)
	e := setup(t, withRulesCtl(c))
	cookies, csrf := e.login()

	c.touch(t, "HOLD")
	var wg sync.WaitGroup
	wg.Add(1)
	var first int
	go func() {
		defer wg.Done()
		first = send(e, "POST", "/api/rules/update", "", cookies, csrf).Code
	}()
	deadline := time.Now().Add(5 * time.Second)
	for !getSources(t, e, cookies).Updating {
		if time.Now().After(deadline) {
			t.Fatal("the update never showed as running")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if w := send(e, "POST", "/api/rules/update", "", cookies, csrf); w.Code != http.StatusConflict {
		t.Errorf("second update: %d, want 409", w.Code)
	}
	if err := os.Remove(filepath.Join(c.dir, "HOLD")); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if first != 200 {
		t.Errorf("first update: %d, want 200", first)
	}
	n := 0
	for _, call := range c.calls(t) {
		if call == "rules-update" {
			n++
		}
	}
	if n != 1 {
		t.Errorf("rules-update ran %d times, want 1", n)
	}
	if getSources(t, e, cookies).Updating {
		t.Error("updating stays true after the update ended")
	}
}

func TestRulesNeedASession(t *testing.T) {
	e := setup(t)
	for _, r := range []struct{ method, path string }{
		{"GET", "/api/rules/sources"}, {"POST", "/api/rules/sources"}, {"POST", "/api/rules/update"},
		{"GET", "/api/rules/search?q=x"}, {"POST", "/api/rules/sid/1/disable"}, {"POST", "/api/rules/groups/x/enable"},
	} {
		if w := e.do(req{method: r.method, path: r.path}); w.Code != http.StatusUnauthorized {
			t.Errorf("%s %s without a session: %d, want 401", r.method, r.path, w.Code)
		}
	}
}
