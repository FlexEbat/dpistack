package api

import (
	"bufio"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/eve"
	"github.com/FlexEbat/dpistack/panel/internal/export"
)

const exportToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// parsed is the exposition text read back by a strict parser of format
// 0.0.4: what promtool would check, for the places where it is not installed.
type parsed struct {
	kind    map[string]string
	samples map[string]map[string]float64 // family -> "labels" -> value
}

var (
	metricName = regexp.MustCompile(`^[a-zA-Z_:][a-zA-Z0-9_:]*$`)
	labelName  = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)
	labelPair  = regexp.MustCompile(`^([^=]+)="((?:[^"\\]|\\[\\"n])*)"$`)
)

func parseExposition(t *testing.T, text string) parsed {
	t.Helper()
	p := parsed{kind: map[string]string{}, samples: map[string]map[string]float64{}}
	if text != "" && !strings.HasSuffix(text, "\n") {
		t.Fatal("the text does not end with a newline")
	}
	helped := map[string]bool{}
	current := ""
	closed := map[string]bool{}
	sc := bufio.NewScanner(strings.NewReader(text))
	for n := 1; sc.Scan(); n++ {
		line := sc.Text()
		fail := func(format string, args ...any) {
			t.Helper()
			t.Fatalf("line %d %q: %s", n, line, fmt.Sprintf(format, args...))
		}
		switch {
		case line == "":
			fail("an empty line")
		case strings.HasPrefix(line, "# HELP "):
			name, _, _ := strings.Cut(strings.TrimPrefix(line, "# HELP "), " ")
			if !metricName.MatchString(name) || helped[name] {
				fail("bad or repeated HELP")
			}
			helped[name] = true
		case strings.HasPrefix(line, "# TYPE "):
			f := strings.Fields(strings.TrimPrefix(line, "# TYPE "))
			if len(f) != 2 || !metricName.MatchString(f[0]) {
				fail("bad TYPE")
			}
			if _, dup := p.kind[f[0]]; dup {
				fail("repeated TYPE")
			}
			if f[1] != "counter" && f[1] != "gauge" {
				fail("unexpected type %q", f[1])
			}
			if f[1] == "counter" && !strings.HasSuffix(f[0], "_total") {
				fail("a counter must end in _total")
			}
			p.kind[f[0]] = f[1]
			if current != "" {
				closed[current] = true
			}
			current = f[0]
			p.samples[f[0]] = map[string]float64{}
		case strings.HasPrefix(line, "#"):
			// a plain comment
		default:
			head, value, ok := strings.Cut(line, " ")
			if !ok {
				fail("a sample without a value")
			}
			name, labels := head, ""
			if i := strings.IndexByte(head, '{'); i >= 0 {
				if !strings.HasSuffix(head, "}") {
					fail("unterminated labels")
				}
				name, labels = head[:i], head[i+1:len(head)-1]
				for _, pair := range splitLabels(labels) {
					m := labelPair.FindStringSubmatch(pair)
					if m == nil || !labelName.MatchString(m[1]) {
						fail("bad label %q", pair)
					}
				}
			}
			if name != current || closed[name] {
				fail("a sample outside the TYPE block of %s", name)
			}
			v, err := strconv.ParseFloat(value, 64)
			if err != nil || math.IsNaN(v) {
				fail("bad value %q", value)
			}
			if _, dup := p.samples[name][labels]; dup {
				fail("a duplicate series")
			}
			p.samples[name][labels] = v
		}
	}
	for name := range p.kind {
		if !helped[name] {
			t.Fatalf("%s has a TYPE but no HELP", name)
		}
		if len(p.samples[name]) == 0 {
			t.Fatalf("%s is announced with no samples", name)
		}
	}
	return p
}

// splitLabels cuts `a="x",b="y"` at the commas outside quotes.
func splitLabels(s string) []string {
	var out []string
	in, esc, start := false, false, 0
	for i := 0; i < len(s); i++ {
		switch {
		case esc:
			esc = false
		case s[i] == '\\':
			esc = true
		case s[i] == '"':
			in = !in
		case s[i] == ',' && !in:
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

// promtool checks the same text when it is installed.
func promtoolCheck(t *testing.T, text string) {
	t.Helper()
	path, err := exec.LookPath("promtool")
	if err != nil {
		return
	}
	cmd := exec.Command(path, "check", "metrics")
	cmd.Stdin = strings.NewReader(text)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("promtool check metrics: %v\n%s", err, out)
	}
}

type exportFixture struct {
	dir    string
	clock  time.Time
	reader *eve.Reader
}

func (f *exportFixture) path(name string) string { return filepath.Join(f.dir, name) }

func (f *exportFixture) write(t *testing.T, name, text string) {
	t.Helper()
	if err := os.WriteFile(f.path(name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func statsLine(ts string, uptime int, packets, drops int) string {
	return fmt.Sprintf(`{"timestamp":%q,"event_type":"stats","stats":{"uptime":%d,"capture":{"kernel_packets":%d,"kernel_drops":%d}}}`+"\n", ts, uptime, packets, drops)
}

// newExportFixture writes a full set of sources and returns the exporter's
// configuration over them.
func newExportFixture(t *testing.T) (*exportFixture, export.Config) {
	t.Helper()
	f := &exportFixture{dir: t.TempDir(), clock: time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)}
	f.write(t, "health.json", `{"ts":"2026-10-15T11:59:50Z","overall":"crit","checks":[
 {"id":"suricata.process","status":"ok","value":"active","detail":"","since":""},
 {"id":"ntopng.process","status":"crit","value":"failed","detail":"","since":""},
 {"id":"evebox.process","status":"na","value":"absent","detail":"","since":""},
 {"id":"disk.free","status":"warn","value":"12.0","detail":"","since":""},
 {"id":"rules.age","status":"ok","value":"1.0","detail":"","since":""},
 {"id":"suricata.drop_rate","status":"na","value":"","detail":"","since":""}]}`)
	f.write(t, "tests-last.json", `{"results":[
{"name":"bittorrent","status":"pass","detail":"","duration_ms":10,"timestamp":"2026-10-15T10:00:00Z"},
{"name":"https","status":"fail","detail":"x","duration_ms":10,"timestamp":"2026-10-15T10:05:00Z"},
{"name":"live","status":"skip","detail":"","duration_ms":0,"timestamp":"2026-10-15T10:06:00Z"}]}`)
	f.write(t, "suricata.rules", "alert\n")
	if err := os.Chtimes(f.path("suricata.rules"), f.clock.Add(-72*time.Hour), f.clock.Add(-72*time.Hour)); err != nil {
		t.Fatal(err)
	}
	f.write(t, "eve.json",
		`{"timestamp":"2026-10-15T11:59:00.000000+0000","event_type":"alert"}`+"\n"+
			`{"timestamp":"2026-10-15T11:59:10.000000+0000","event_type":"dns"}`+"\n"+
			statsLine("2026-10-15T11:59:20.000000+0000", 100, 10000, 100)+
			statsLine("2026-10-15T11:59:50.000000+0000", 130, 40000, 400)+
			`{"timestamp":"2026-10-15T11:59:55.000000+0000","event_type":"alert"}`+"\n")
	f.reader = eve.New(f.path("eve.json"))
	return f, export.Config{
		HealthFile: f.path("health.json"), TestsFile: f.path("tests-last.json"),
		RulesFile: f.path("suricata.rules"), EveFile: f.path("eve.json"),
		DiskPaths: []string{f.dir}, Eve: f.reader,
		Proc: func() (time.Duration, int64, bool) { return 0, 9 << 20, true },
		Now:  func() time.Time { return f.clock },
	}
}

func withExport(cfg export.Config, token string) option {
	return func(c *Config, _ string) {
		c.Export = export.New(cfg)
		c.ExportToken = token
	}
}

func scrape(e *env, auth string) *httpResultRec {
	h := map[string]string{}
	if auth != "" {
		h["Authorization"] = auth
	}
	w := e.do(req{method: "GET", path: "/metrics", headers: h})
	return &httpResultRec{code: w.Code, body: w.Body.String(), ctype: w.Header().Get("Content-Type")}
}

type httpResultRec struct {
	code        int
	body, ctype string
}

// Criterion 1: no token and a wrong token are 401, the right one is 200 with
// the Prometheus content type, and no session is needed.
func TestMetricsExportNeedsTheToken(t *testing.T) {
	_, cfg := newExportFixture(t)
	e := setup(t, withExport(cfg, exportToken))

	for name, auth := range map[string]string{
		"no header":       "",
		"wrong token":     "Bearer " + strings.Repeat("0", len(exportToken)),
		"token no Bearer": exportToken,
		"basic":           "Basic " + exportToken,
		"prefix only":     "Bearer " + exportToken[:10],
		"token plus one":  "Bearer " + exportToken + "0",
		"empty bearer":    "Bearer ",
	} {
		if r := scrape(e, auth); r.code != http.StatusUnauthorized {
			t.Errorf("%s: %d, want 401", name, r.code)
		} else if strings.Contains(r.body, "dpistack_") {
			t.Errorf("%s: metrics leaked into a 401", name)
		}
	}
	if r := scrape(e, "bearer "+exportToken); r.code != 200 {
		t.Errorf("the scheme is case-insensitive: %d", r.code)
	}
	r := scrape(e, "Bearer "+exportToken)
	if r.code != 200 {
		t.Fatalf("right token: %d %s", r.code, r.body)
	}
	if !strings.HasPrefix(r.ctype, "text/plain; version=0.0.4") {
		t.Errorf("content type %q", r.ctype)
	}
	// The address policy of 4.8 still guards it.
	w := e.do(req{method: "GET", path: "/metrics", remote: "203.0.113.9:5555", headers: map[string]string{"Authorization": "Bearer " + exportToken}})
	if w.Code != http.StatusForbidden {
		t.Errorf("a foreign address got %d, want 403", w.Code)
	}
}

// Criterion 4: METRICS_EXPORT=no (no token, no exporter) is a 404, even for a
// request that carries some token.
func TestMetricsExportOffIs404(t *testing.T) {
	e := setup(t)
	for _, auth := range []string{"", "Bearer " + exportToken} {
		if r := scrape(e, auth); r.code != http.StatusNotFound {
			t.Errorf("auth %q: %d, want 404", auth, r.code)
		}
	}
	_, cfg := newExportFixture(t)
	e = setup(t, withExport(cfg, "")) // an exporter with no token must not serve anyone
	if r := scrape(e, "Bearer "); r.code != http.StatusNotFound {
		t.Errorf("empty token: %d, want 404", r.code)
	}
}

// Criteria 2 and 3: everything of 4.9 is there when the data is, the text is
// valid exposition, and what is `na` or skipped is not.
func TestMetricsExportHasEverythingOf49(t *testing.T) {
	_, cfg := newExportFixture(t)
	e := setup(t, withExport(cfg, exportToken))
	r := scrape(e, "Bearer "+exportToken)
	promtoolCheck(t, r.body)
	p := parseExposition(t, r.body)

	want := map[string]string{
		"dpistack_component_up": "gauge", "dpistack_check_status": "gauge",
		"dpistack_suricata_kernel_packets_total": "counter", "dpistack_suricata_kernel_drops_total": "counter",
		"dpistack_suricata_drop_ratio": "gauge", "dpistack_suricata_uptime_seconds": "gauge",
		"dpistack_eve_events_total": "counter", "dpistack_eve_size_bytes": "gauge",
		"dpistack_eve_last_event_age_seconds": "gauge", "dpistack_disk_free_ratio": "gauge",
		"dpistack_rules_age_seconds": "gauge", "dpistack_test_status": "gauge",
		"dpistack_test_timestamp_seconds": "gauge", "dpistack_panel_rss_bytes": "gauge",
	}
	for name, kind := range want {
		if p.kind[name] != kind {
			t.Errorf("%s: type %q, want %q", name, p.kind[name], kind)
		}
	}
	if len(p.kind) != len(want) {
		t.Errorf("%d families, want %d: %v", len(p.kind), len(want), p.kind)
	}

	check := func(name, labels string, want float64) {
		t.Helper()
		got, ok := p.samples[name][labels]
		if !ok || math.Abs(got-want) > 1e-9 {
			t.Errorf("%s{%s} = %v (present %v), want %v", name, labels, got, ok, want)
		}
	}
	check("dpistack_component_up", `component="suricata"`, 1)
	check("dpistack_component_up", `component="ntopng"`, 0)
	check("dpistack_check_status", `check="disk.free"`, 1)
	check("dpistack_check_status", `check="ntopng.process"`, 2)
	check("dpistack_check_status", `check="rules.age"`, 0)
	check("dpistack_suricata_kernel_packets_total", "", 40000)
	check("dpistack_suricata_kernel_drops_total", "", 400)
	check("dpistack_suricata_drop_ratio", "", 0.01) // 300 of 30000
	check("dpistack_suricata_uptime_seconds", "", 130)
	check("dpistack_eve_events_total", `event_type="alert"`, 2)
	check("dpistack_eve_events_total", `event_type="stats"`, 2)
	check("dpistack_eve_last_event_age_seconds", "", 5)
	check("dpistack_rules_age_seconds", "", 72*3600)
	check("dpistack_test_status", `test="bittorrent"`, 1)
	check("dpistack_test_status", `test="https"`, 0)
	check("dpistack_test_timestamp_seconds", `test="bittorrent"`, float64(time.Date(2026, 10, 15, 10, 0, 0, 0, time.UTC).Unix()))
	check("dpistack_panel_rss_bytes", "", 9<<20)
	if got := p.samples["dpistack_eve_size_bytes"][""]; got <= 0 {
		t.Errorf("eve size %v", got)
	}
	if got := p.samples["dpistack_disk_free_ratio"][`path="`+cfg.DiskPaths[0]+`"`]; got <= 0 || got > 1 {
		t.Errorf("disk free %v", got)
	}

	// na checks and skipped tests are not offered.
	for name, labels := range map[string]string{
		"dpistack_check_status": `check="evebox.process"`,
		"dpistack_component_up": `component="evebox"`,
		"dpistack_test_status":  `test="live"`,
	} {
		if _, ok := p.samples[name][labels]; ok {
			t.Errorf("%s{%s} must not be shown", name, labels)
		}
	}
	if _, ok := p.samples["dpistack_check_status"][`check="suricata.drop_rate"`]; ok {
		t.Error("a na check is shown")
	}
	if strings.Contains(r.body, exportToken) {
		t.Error("the token is in the output")
	}
}

// Criterion 2, the other half: what depends on eve.json is not offered
// without it, whatever else is.
func TestMetricsExportLeavesOutWhatHasNoData(t *testing.T) {
	f, cfg := newExportFixture(t)

	// EVE_FILE=no: no reader at all.
	off := cfg
	off.Eve, off.EveFile = nil, ""
	e := setup(t, withExport(off, exportToken))
	body := scrape(e, "Bearer "+exportToken).body
	parseExposition(t, body)
	for _, prefix := range []string{"dpistack_suricata_", "dpistack_eve_"} {
		if strings.Contains(body, prefix) {
			t.Errorf("EVE_FILE=no still offers %s*", prefix)
		}
	}
	for _, name := range []string{"dpistack_component_up", "dpistack_disk_free_ratio", "dpistack_panel_rss_bytes", "dpistack_rules_age_seconds"} {
		if !strings.Contains(body, name) {
			t.Errorf("%s vanished with EVE_FILE=no", name)
		}
	}

	// EVE_FILE=yes but no stats in EVE_TYPES: the eve metrics stay, the
	// Suricata counters go.
	f.write(t, "eve.json", `{"timestamp":"2026-10-15T11:59:55.000000+0000","event_type":"alert"}`+"\n")
	nostats := cfg
	nostats.Eve = eve.New(f.path("eve.json"))
	e = setup(t, withExport(nostats, exportToken))
	body = scrape(e, "Bearer "+exportToken).body
	parseExposition(t, body)
	if strings.Contains(body, "dpistack_suricata_") {
		t.Error("counters offered without stats events")
	}
	if !strings.Contains(body, "dpistack_eve_events_total") || !strings.Contains(body, "dpistack_eve_size_bytes") {
		t.Error("the eve metrics must stay without stats")
	}

	// Nothing there at all: no health.json, tests, rules or eve.json.
	empty := export.Config{
		HealthFile: f.path("none1"), TestsFile: f.path("none2"), RulesFile: f.path("none3"),
		EveFile: f.path("none4"), Eve: eve.New(f.path("none4")), DiskPaths: []string{f.path("nodir")},
		Now: func() time.Time { return f.clock },
	}
	e = setup(t, withExport(empty, exportToken))
	if r := scrape(e, "Bearer "+exportToken); r.code != 200 || r.body != "" {
		t.Errorf("with no data: %d %q, want an empty 200", r.code, r.body)
	}

	// A damaged health.json and tests file are skipped, not fatal.
	f.write(t, "health.json", "{broken")
	f.write(t, "tests-last.json", "[1,2")
	e = setup(t, withExport(cfg, exportToken))
	body = scrape(e, "Bearer "+exportToken).body
	parseExposition(t, body)
	if strings.Contains(body, "dpistack_check_status") || strings.Contains(body, "dpistack_test_status") {
		t.Error("data from a damaged file")
	}
}

// Criterion 5: counters that went down never give a negative ratio.
func TestMetricsDropRatioNeverNegative(t *testing.T) {
	f, cfg := newExportFixture(t)
	cases := []struct {
		name     string
		older    [2]int // packets, drops
		newer    [2]int
		want     float64
		wantSeen bool
	}{
		{"normal", [2]int{1000, 10}, [2]int{2000, 60}, 0.05, true},
		{"packets reset", [2]int{50000, 10}, [2]int{300, 2}, 0, false},
		{"drops reset", [2]int{50000, 900}, [2]int{60000, 5}, 0, false},
		{"idle, nothing moved", [2]int{1000, 10}, [2]int{1000, 10}, 0, true},
		{"drops without packets", [2]int{1000, 10}, [2]int{1000, 20}, 0, false},
		{"more drops than packets", [2]int{1000, 0}, [2]int{1100, 500}, 1, true},
	}
	for _, c := range cases {
		f.write(t, "eve.json",
			statsLine("2026-10-15T11:59:20.000000+0000", 100, c.older[0], c.older[1])+
				statsLine("2026-10-15T11:59:50.000000+0000", 130, c.newer[0], c.newer[1]))
		cfg.Eve = eve.New(f.path("eve.json"))
		e := setup(t, withExport(cfg, exportToken))
		body := scrape(e, "Bearer "+exportToken).body
		p := parseExposition(t, body)
		got, seen := p.samples["dpistack_suricata_drop_ratio"][""]
		if seen != c.wantSeen || (seen && math.Abs(got-c.want) > 1e-9) {
			t.Errorf("%s: ratio %v (shown %v), want %v (shown %v)", c.name, got, seen, c.want, c.wantSeen)
		}
		if got < 0 || got > 1 {
			t.Errorf("%s: ratio %v is out of 0..1", c.name, got)
		}
	}
}

// Criterion 7: a burst of requests reads the disk once; after the interval
// it reads again.
func TestMetricsExportReadsDiskAtMostOncePerSecond(t *testing.T) {
	f, cfg := newExportFixture(t)
	reads := map[string]int{}
	cfg.IO = export.IO{
		ReadFile: func(p string) ([]byte, error) { reads["read"]++; return os.ReadFile(p) },
		Stat: func(p string) (int64, time.Time, bool) {
			reads["stat"]++
			st, err := os.Stat(p)
			if err != nil {
				return 0, time.Time{}, false
			}
			return st.Size(), st.ModTime(), true
		},
		DiskFree: func(string) (float64, bool) { reads["statfs"]++; return 0.5, true },
		Poll:     func() error { reads["poll"]++; return cfg.Eve.Poll() },
	}
	exp := export.New(cfg)
	e := setup(t, func(c *Config, _ string) { c.Export, c.ExportToken = exp, exportToken })

	for i := 0; i < 200; i++ {
		if r := scrape(e, "Bearer "+exportToken); r.code != 200 {
			t.Fatalf("request %d: %d", i, r.code)
		}
	}
	if exp.Gathers() != 1 {
		t.Fatalf("200 requests in one second gathered %d times, want 1", exp.Gathers())
	}
	// read: health + tests; stat: eve + rules; statfs: one path; poll: one.
	if reads["read"] != 2 || reads["stat"] != 2 || reads["statfs"] != 1 || reads["poll"] != 1 {
		t.Errorf("disk accesses for 200 requests: %v", reads)
	}

	f.clock = f.clock.Add(999 * time.Millisecond)
	scrape(e, "Bearer "+exportToken)
	if exp.Gathers() != 1 {
		t.Error("it read again before a second had passed")
	}
	f.clock = f.clock.Add(2 * time.Millisecond)
	scrape(e, "Bearer "+exportToken)
	if exp.Gathers() != 2 {
		t.Errorf("after the second it did not read again: %d gathers", exp.Gathers())
	}
	// A clock that went backwards must not freeze the cache.
	f.clock = f.clock.Add(-time.Hour)
	scrape(e, "Bearer "+exportToken)
	if exp.Gathers() != 3 {
		t.Errorf("after a step back in time: %d gathers, want 3", exp.Gathers())
	}
}

// Label values are escaped, so a test name cannot break the text.
func TestMetricsExportEscapesLabels(t *testing.T) {
	f, cfg := newExportFixture(t)
	f.write(t, "tests-last.json", `{"results":[{"name":"a\"b\\c\nd","status":"pass","timestamp":"2026-10-15T10:00:00Z"}]}`)
	e := setup(t, withExport(cfg, exportToken))
	body := scrape(e, "Bearer "+exportToken).body
	parseExposition(t, body)
	if !strings.Contains(body, `test="a\"b\\c\nd"`) {
		t.Errorf("label not escaped:\n%s", body)
	}
}
