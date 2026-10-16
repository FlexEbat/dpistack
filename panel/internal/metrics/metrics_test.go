package metrics

import (
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/eve"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newClock() *clock { return &clock{t: time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)} }

// feed is a scripted stats source: the test sets what the "newest stats
// event" is before each tick.
type feed struct {
	st Stats
	ok bool
}

func (f *feed) stats() (Stats, bool) { return f.st, f.ok }

func lastValue(t *testing.T, c *Collector, s Series) float64 {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ring[len(c.ring)-1].V[s]
}

// Criterion 3: counters of Suricata that go down (it restarted) skip the
// interval; the graph never gets a negative value, and not a zero either.
func TestCounterResetNeverGoesNegative(t *testing.T) {
	clk, f := newClock(), &feed{ok: true}
	c := New(Config{Inputs: Inputs{Stats: f.stats}, Now: clk.now})

	type step struct {
		id      uint64
		packets uint64
		drops   uint64
		uptime  float64
		wantPPS float64 // NaN: no value expected
		wantDrp float64
	}
	steps := []step{
		{1, 1000, 10, 100, math.NaN(), math.NaN()}, // first event: no previous
		{2, 4000, 70, 130, 100, 2},                 // +3000 packets, +60 drops in 30 s
		{2, 4000, 70, 130, math.NaN(), math.NaN()}, // no new stats event
		{3, 500, 5, 10, math.NaN(), math.NaN()},    // Suricata restarted: reset
		{4, 3500, 35, 40, 100, 1},                  // counting again from the new base
		{5, 3600, 3, 70, math.NaN(), math.NaN()},   // drops alone went down: still a reset
		{6, 6600, 33, 130, 50, 0.5},                // +3000 in 60 s of uptime, +30 drops
	}
	for i, s := range steps {
		clk.advance(30 * time.Second)
		f.st = Stats{ID: s.id, Packets: s.packets, Drops: s.drops, Uptime: s.uptime, Time: clk.t}
		c.Sample()
		for _, w := range []struct {
			name string
			got  float64
			want float64
		}{{"pps", lastValue(t, c, PPS), s.wantPPS}, {"drops", lastValue(t, c, Drops), s.wantDrp}} {
			if math.IsNaN(w.want) != math.IsNaN(w.got) || (!math.IsNaN(w.want) && math.Abs(w.got-w.want) > 1e-9) {
				t.Errorf("step %d %s = %v, want %v", i, w.name, w.got, w.want)
			}
		}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, s := range c.ring {
		for i, v := range s.V {
			if !math.IsNaN(v) && v < 0 {
				t.Fatalf("negative value %v in series %s", v, Names[i])
			}
		}
	}
}

// Without an uptime in the event the rate uses the timestamps.
func TestRateFromTimestampsWhenThereIsNoUptime(t *testing.T) {
	clk, f := newClock(), &feed{ok: true}
	c := New(Config{Inputs: Inputs{Stats: f.stats}, Now: clk.now})
	f.st = Stats{ID: 1, Packets: 100, Time: clk.t}
	c.Sample()
	clk.advance(10 * time.Second)
	f.st = Stats{ID: 2, Packets: 600, Time: clk.t}
	c.Sample()
	if got := lastValue(t, c, PPS); got != 50 {
		t.Errorf("pps = %v, want 50", got)
	}
}

func TestCPUAndRSS(t *testing.T) {
	clk := newClock()
	cpu := time.Duration(0)
	rss := int64(10 << 20)
	c := New(Config{Now: clk.now, Inputs: Inputs{Proc: func() (time.Duration, int64, bool) { return cpu, rss, true }}})
	c.Sample()
	if !math.IsNaN(lastValue(t, c, CPU)) {
		t.Error("the first tick has nothing to compare with, cpu must be unknown")
	}
	clk.advance(30 * time.Second)
	cpu += 3 * time.Second
	c.Sample()
	if got := lastValue(t, c, CPU); math.Abs(got-10) > 1e-9 {
		t.Errorf("cpu = %v, want 10 percent", got)
	}
	if got := lastValue(t, c, RSS); got != float64(10<<20) {
		t.Errorf("rss = %v", got)
	}
	rss = -1 // unreadable: unknown, never zero
	clk.advance(30 * time.Second)
	c.Sample()
	if !math.IsNaN(lastValue(t, c, RSS)) {
		t.Error("an unreadable rss was drawn as a value")
	}
}

// Criterion 2: a restarted panel has the series again, from metrics.json.
func TestRingIsRestoredAfterARestart(t *testing.T) {
	clk := newClock()
	file := filepath.Join(t.TempDir(), "metrics.json")
	f := &feed{ok: true}
	size := int64(1000)
	mk := func() *Collector {
		return New(Config{File: file, Now: clk.now, Inputs: Inputs{
			Stats:    f.stats,
			EveSize:  func() (int64, bool) { return size, true },
			DiskFree: func() (float64, bool) { return 0.42, true },
			Proc:     func() (time.Duration, int64, bool) { return 0, 5 << 20, true },
		}})
	}
	a := mk()
	for i := 1; i <= 20; i++ {
		clk.advance(30 * time.Second)
		f.st = Stats{ID: uint64(i), Packets: uint64(i) * 3000, Drops: uint64(i) * 30, Uptime: float64(i) * 30, Time: clk.t}
		size += 500
		a.Sample()
	}
	if err := a.Save(); err != nil {
		t.Fatal(err)
	}
	want, err := a.Query("1h")
	if err != nil {
		t.Fatal(err)
	}

	clk.advance(2 * time.Minute) // the panel was down for a while
	b := mk()
	if b.Len() != a.Len() {
		t.Fatalf("restored %d samples, had %d", b.Len(), a.Len())
	}
	got, _ := b.Query("1h")
	// Compare on the grid, leaving out the minutes of downtime that moved it.
	shift := int((got.Start - want.Start) / int64(want.Step))
	if shift != 4 {
		t.Fatalf("grid moved by %d buckets, want 4", shift)
	}
	for _, name := range Names {
		w, g := want.Series[name].Values, got.Series[name].Values
		for k := range w {
			if k >= shift && k < len(w) {
				wv, gv := w[k], g[k-shift]
				if (wv == nil) != (gv == nil) || (wv != nil && math.Abs(*wv-*gv) > 1e-9) {
					t.Fatalf("%s bucket %d: restored %v, was %v", name, k, gv, wv)
				}
			}
		}
	}
	if v := got.Series["pps"].Values; v[len(v)-1-4] == nil || math.Abs(*v[len(v)-1-4]-100) > 1e-9 {
		t.Errorf("pps after restore: %v", v[len(v)-5])
	}
}

func TestRestoreKeepsOnlyTheLastDayAndSurvivesBadFiles(t *testing.T) {
	clk := newClock()
	dir := t.TempDir()
	row := func(t int64) string { return fmt.Sprintf("[%d,1,2,3,4,5,0.5]", t) }
	now := clk.t.Unix()
	rows := []string{
		row(now - 90000), // older than 24 h
		row(now - 120),   // good
		row(now - 60),    // good
		row(now - 90),    // out of order
		row(now + 10000), // from the future
		"[1,2]",          // wrong width
	}
	good := fmt.Sprintf(`{"version":1,"step_seconds":30,"saved":%d,"samples":[%s]}`, now, strings.Join(rows, ","))
	cases := []struct {
		name, content string
		want          int
	}{
		{"mixed rows", good, 2},
		{"empty file", "", 0},
		{"garbage", "{not json", 0},
		{"truncated", good[:len(good)/2], 0},
		{"other version", strings.Replace(good, `"version":1`, `"version":99`, 1), 0},
		{"no file", "", 0},
	}
	for _, tc := range cases {
		path := filepath.Join(dir, tc.name+".json")
		if tc.name != "no file" {
			if err := os.WriteFile(path, []byte(tc.content), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		c := New(Config{File: path, Now: clk.now})
		if c.Len() != tc.want {
			t.Errorf("%s: %d samples, want %d", tc.name, c.Len(), tc.want)
		}
		c.Sample() // a damaged file must not break sampling
	}
}

// Criterion 4: never more than 24 hours at 30 seconds.
func TestRingNeverExceedsADay(t *testing.T) {
	if time.Duration(Capacity)*Step != Window || Window != 24*time.Hour || Step != 30*time.Second {
		t.Fatalf("capacity %d x %v is not a day of 30 s", Capacity, Step)
	}
	clk := newClock()
	c := New(Config{Now: clk.now})
	for i := 0; i < Capacity+500; i++ {
		clk.advance(Step)
		c.Sample()
	}
	if c.Len() != Capacity {
		t.Fatalf("ring holds %d samples, want %d", c.Len(), Capacity)
	}
	c.mu.Lock()
	span := time.Duration(c.ring[len(c.ring)-1].T-c.ring[0].T) * time.Second
	c.mu.Unlock()
	if span >= Window {
		t.Errorf("ring spans %v, must be under 24 h", span)
	}

	// A file with more rows than fit is cut to the newest ones.
	var rows []string
	now := clk.t.Unix()
	for i := 4000; i > 0; i-- {
		rows = append(rows, fmt.Sprintf("[%d,1,2,3,4,5,0.5]", now-int64(i)*20))
	}
	path := filepath.Join(t.TempDir(), "big.json")
	data := fmt.Sprintf(`{"version":1,"step_seconds":30,"saved":%d,"samples":[%s]}`, now, strings.Join(rows, ","))
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	if n := New(Config{File: path, Now: clk.now}).Len(); n != Capacity {
		t.Errorf("a 4000-row file restored %d samples, want %d", n, Capacity)
	}
}

// Criterion 5 (the server's half): a series that cannot exist is marked,
// and its values are null, not zero.
func TestUnavailableSeriesAreMarkedNotZero(t *testing.T) {
	clk := newClock()
	c := New(Config{Now: clk.now, Inputs: Inputs{Proc: func() (time.Duration, int64, bool) { return time.Second, 1 << 20, true }}})
	for i := 0; i < 5; i++ {
		clk.advance(Step)
		c.Sample()
	}
	res, err := c.Query("1h")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"pps", "drops", "eve_size", "disk"} {
		s := res.Series[name]
		if s.Available || !strings.Contains(s.Reason, "EVE_FILE=no") {
			t.Errorf("%s with EVE_FILE=no: available=%v reason=%q", name, s.Available, s.Reason)
		}
		for _, v := range s.Values {
			if v != nil {
				t.Fatalf("%s has a value %v where it cannot have one", name, *v)
			}
		}
	}
	for _, name := range []string{"cpu", "rss"} {
		if !res.Series[name].Available {
			t.Errorf("%s must be available", name)
		}
	}

	// EVE_FILE=yes but no stats events: the packet series are off, the file
	// series work.
	f := &feed{}
	c = New(Config{Now: clk.now, Inputs: Inputs{
		Stats:    f.stats,
		EveSize:  func() (int64, bool) { return 0, false }, // the file is not there yet
		DiskFree: func() (float64, bool) { return 0.5, true },
	}})
	c.Sample()
	res, _ = c.Query("1h")
	if s := res.Series["pps"]; s.Available || !strings.Contains(s.Reason, "stats") {
		t.Errorf("pps without stats: %+v", s)
	}
	if s := res.Series["eve_size"]; !s.Available {
		t.Error("eve_size is a real series even while the file is missing")
	} else {
		for _, v := range s.Values {
			if v != nil {
				t.Fatal("a missing file was drawn as a size")
			}
		}
	}
	f.ok, f.st = true, Stats{ID: 1, Packets: 1, Time: clk.t}
	c.Sample()
	res, _ = c.Query("1h")
	if !res.Series["pps"].Available {
		t.Error("pps stays off after stats events appeared")
	}
}

func TestQueryGrids(t *testing.T) {
	clk := newClock()
	rss := int64(0)
	c := New(Config{Now: clk.now, Inputs: Inputs{Proc: func() (time.Duration, int64, bool) { return 0, rss, true }}})
	// Four hours of samples with a gap in the middle; rss counts the ticks.
	for i := 0; i < 480; i++ {
		clk.advance(Step)
		rss = int64(i + 1)
		if i >= 200 && i < 260 {
			continue // no samples for 30 minutes
		}
		c.Sample()
	}
	for rng, want := range map[string]struct{ n, step int }{"1h": {120, 30}, "6h": {180, 120}, "24h": {180, 480}} {
		res, err := c.Query(rng)
		if err != nil {
			t.Fatal(err)
		}
		if res.Step != want.step || len(res.Series["rss"].Values) != want.n {
			t.Errorf("%s: step %d with %d points, want %d with %d", rng, res.Step, len(res.Series["rss"].Values), want.step, want.n)
		}
		if res.Start != clk.t.Unix()-int64(want.n*want.step)+1 {
			t.Errorf("%s: start %d", rng, res.Start)
		}
	}
	res, _ := c.Query("6h")
	vals := res.Series["rss"].Values
	// The newest bucket is the mean of the samples inside it.
	if vals[len(vals)-1] == nil || *vals[len(vals)-1] < 470 {
		t.Errorf("newest bucket: %v", vals[len(vals)-1])
	}
	nils := 0
	for _, v := range vals {
		if v == nil {
			nils++
		}
	}
	// 6 h grid is 180 buckets; 4 h of data fills 120, the gap makes 15 more empty ones.
	if nils < 60+10 {
		t.Errorf("expected empty buckets for the window before the data and for the gap, got %d", nils)
	}
	if _, err := c.Query("7d"); err == nil {
		t.Error("an arbitrary period must be refused")
	}
	if _, err := c.Query(""); err == nil {
		t.Error("an empty range must be refused")
	}
}

func TestRunSamplesAtOnceAndSavesOnStop(t *testing.T) {
	file := filepath.Join(t.TempDir(), "metrics.json")
	var ticks atomic.Int64 // every reading of the clock is half a minute later
	base := time.Now()
	c := New(Config{File: file, Step: 10 * time.Millisecond, Now: func() time.Time {
		return base.Add(time.Duration(ticks.Add(1)) * 30 * time.Second)
	}, Inputs: Inputs{
		Proc: func() (time.Duration, int64, bool) { return 0, 1 << 20, true },
	}})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { c.Run(ctx); close(done) }()
	deadline := time.Now().Add(3 * time.Second)
	for c.Len() < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("Run did not stop")
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatalf("nothing saved on stop: %v", err)
	}
	if n := New(Config{File: file, Now: func() time.Time { return base.Add(24 * time.Hour) }}).Len(); n < 3 {
		t.Errorf("the file holds %d samples", n)
	}
}

func TestSaveRewritesTheFileInPlace(t *testing.T) {
	clk := newClock()
	file := filepath.Join(t.TempDir(), "metrics.json")
	if err := os.WriteFile(file, []byte(strings.Repeat("x", 100000)), 0o640); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(file)
	c := New(Config{File: file, Now: clk.now, Inputs: Inputs{Proc: func() (time.Duration, int64, bool) { return 0, 1, true }}})
	c.Sample()
	if err := c.Save(); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(file)
	if !os.SameFile(before, after) {
		t.Error("the file was replaced; the panel may not be able to do that in the state directory")
	}
	if after.Size() >= 100000 {
		t.Errorf("old bytes left after the new content: %d", after.Size())
	}
	if New(Config{File: file, Now: clk.now}).Len() != 1 {
		t.Error("the rewritten file does not load")
	}
}

func TestEveStatsReadsTheNewestStatsEvent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eve.json")
	line := func(ts string, uptime int, packets, drops int) string {
		return fmt.Sprintf(`{"timestamp":%q,"event_type":"stats","stats":{"uptime":%d,"capture":{"kernel_packets":%d,"kernel_drops":%d}}}`+"\n", ts, uptime, packets, drops)
	}
	if err := os.WriteFile(path, []byte(`{"timestamp":"2026-10-15T10:00:00.000000+0000","event_type":"alert"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	src := EveStats(eve.New(path))
	if _, ok := src(); ok {
		t.Fatal("stats from a file with no stats events")
	}
	h, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	h.WriteString(line("2026-10-15T10:00:08.000000+0000", 8, 1000, 1) + line("2026-10-15T10:00:16.000000+0000", 16, 2500, 4))
	h.Close()
	st, ok := src()
	if !ok || st.Packets != 2500 || st.Drops != 4 || st.Uptime != 16 || st.Time.Second() != 16 {
		t.Fatalf("stats: %+v ok=%v", st, ok)
	}

	// The whole chain on a real file: two ticks, one rate.
	clk := newClock()
	reader := eve.New(path)
	c := New(Config{Now: clk.now, Inputs: Inputs{Stats: EveStats(reader), EveSize: FileSize(path), DiskFree: DiskFree(path)}})
	c.Sample()
	h, _ = os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	h.WriteString(line("2026-10-15T10:00:24.000000+0000", 24, 4100, 4))
	h.Close()
	clk.advance(30 * time.Second)
	c.Sample()
	if got := lastValue(t, c, PPS); math.Abs(got-200) > 1e-9 {
		t.Errorf("pps over the real file = %v, want 200", got)
	}
	if got := lastValue(t, c, EveSize); got <= 0 {
		t.Errorf("eve size %v", got)
	}
	if got := lastValue(t, c, Disk); got <= 0 || got > 1 {
		t.Errorf("disk free ratio %v", got)
	}
}

func TestProcReportsThisProcess(t *testing.T) {
	cpu, rss, ok := Proc()
	if !ok || cpu < 0 {
		t.Fatalf("Proc: %v %v %v", cpu, rss, ok)
	}
	if rss <= 0 && rss != -1 {
		t.Errorf("rss %d", rss)
	}
	if _, err := os.Stat("/proc/self/statm"); err == nil && rss <= 0 {
		t.Errorf("/proc is there but rss is %d", rss)
	}
}
