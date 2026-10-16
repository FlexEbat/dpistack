package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/metrics"
)

func withMetrics(c *metrics.Collector) option {
	return func(cfg *Config, _ string) { cfg.Metrics = c }
}

type metricsAnswer struct {
	Range  string
	Start  int64
	Step   int
	Series map[string]struct {
		Unit      string
		Available bool
		Reason    string
		Values    []*float64
	}
	Error string
}

func getMetrics(t *testing.T, e *env, query string) (int, metricsAnswer) {
	t.Helper()
	cookies, _ := e.login()
	w := e.do(req{method: "GET", path: "/api/metrics" + query, cookies: cookies})
	var a metricsAnswer
	if err := json.Unmarshal(w.Body.Bytes(), &a); err != nil {
		t.Fatalf("not JSON: %q", w.Body)
	}
	return w.Code, a
}

// The screen gets every series on one grid; a series that cannot exist is
// marked and carries null, not zero.
func TestMetricsAnswer(t *testing.T) {
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	c := metrics.New(metrics.Config{Now: func() time.Time { return now }, Inputs: metrics.Inputs{
		Proc: func() (time.Duration, int64, bool) { return 0, 8 << 20, true },
	}})
	for i := 0; i < 4; i++ {
		now = now.Add(30 * time.Second)
		c.Sample()
	}
	e := setup(t, withMetrics(c))

	code, a := getMetrics(t, e, "?range=1h")
	if code != 200 || a.Range != "1h" || a.Step != 30 || len(a.Series) != 6 {
		t.Fatalf("1h: %d %+v", code, a)
	}
	for _, name := range []string{"pps", "drops", "cpu", "rss", "eve_size", "disk"} {
		s, ok := a.Series[name]
		if !ok || s.Unit == "" || len(s.Values) != 120 {
			t.Errorf("%s: %+v", name, s)
		}
	}
	rss := a.Series["rss"]
	if !rss.Available || rss.Values[119] == nil || *rss.Values[119] != float64(8<<20) {
		t.Errorf("rss: %+v", rss.Values[115:])
	}
	pps := a.Series["pps"]
	if pps.Available || !strings.Contains(pps.Reason, "EVE_FILE=no") {
		t.Errorf("pps must be marked unavailable: %+v", pps)
	}
	for _, v := range pps.Values {
		if v != nil {
			t.Fatal("an unavailable series carries a number")
		}
	}

	if code, a := getMetrics(t, e, ""); code != 200 || a.Range != "1h" {
		t.Errorf("default range: %d %q", code, a.Range)
	}
	for _, r := range []string{"6h", "24h"} {
		if code, a := getMetrics(t, e, "?range="+r); code != 200 || a.Range != r || len(a.Series["rss"].Values) != 180 {
			t.Errorf("%s: %d, %d points", r, code, len(a.Series["rss"].Values))
		}
	}
	for _, bad := range []string{"?range=7d", "?range=2h", "?range=24H", "?range=1h%3B"} {
		if code, _ := getMetrics(t, e, bad); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", bad, code)
		}
	}
}

func TestMetricsNeedASessionAndACollector(t *testing.T) {
	e := setup(t, withMetrics(metrics.New(metrics.Config{})))
	if w := e.do(req{method: "GET", path: "/api/metrics"}); w.Code != http.StatusUnauthorized {
		t.Errorf("without a session: %d, want 401", w.Code)
	}
	if code, _ := getMetrics(t, setup(t), ""); code != http.StatusServiceUnavailable {
		t.Errorf("without a collector: %d, want 503", code)
	}
}
