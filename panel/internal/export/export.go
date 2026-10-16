// Package export renders the panel's state as Prometheus text exposition
// (format 0.0.4, tech.md 4.9) for GET /metrics.
//
// A metric whose data is not there is left out, not shown as zero: a check
// that is `na`, a test that was skipped, everything about eve.json when
// EVE_FILE=no, everything about Suricata's counters when `stats` is not in
// EVE_TYPES. Disk is read at most once per MinInterval however many requests
// arrive; in between, the text of the last read is served.
package export

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/eve"
	"github.com/FlexEbat/dpistack/panel/internal/health"
	"github.com/FlexEbat/dpistack/panel/internal/metrics"
)

// MinInterval is how long a rendered answer is reused.
const MinInterval = time.Second

// maxFile keeps a damaged file from filling memory.
const maxFile = 1 << 20

// IO is every way the exporter touches the disk, so a test can count them.
type IO struct {
	ReadFile func(path string) ([]byte, error)
	Stat     func(path string) (size int64, mtime time.Time, ok bool)
	DiskFree func(dir string) (ratio float64, ok bool)
	Poll     func() error // reads what was appended to eve.json
}

// Config says where the numbers come from. An empty path switches its source
// off; a nil Eve means EVE_FILE=no.
type Config struct {
	HealthFile string
	TestsFile  string
	RulesFile  string
	EveFile    string
	DiskPaths  []string
	Eve        *eve.Reader
	Proc       func() (time.Duration, int64, bool)
	Now        func() time.Time // nil means time.Now
	Interval   time.Duration    // zero means MinInterval
	IO         IO               // nil fields use the real disk
}

// Exporter renders the metrics.
type Exporter struct {
	cfg Config

	mu      sync.Mutex
	at      time.Time
	body    []byte
	gathers int
}

// New returns an Exporter.
func New(cfg Config) *Exporter {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Interval <= 0 {
		cfg.Interval = MinInterval
	}
	if cfg.IO.ReadFile == nil {
		cfg.IO.ReadFile = readFile
	}
	if cfg.IO.Stat == nil {
		cfg.IO.Stat = stat
	}
	if cfg.IO.DiskFree == nil {
		cfg.IO.DiskFree = metrics.FreeRatio
	}
	if cfg.IO.Poll == nil {
		cfg.IO.Poll = func() error {
			if cfg.Eve == nil {
				return nil
			}
			return cfg.Eve.Poll()
		}
	}
	return &Exporter{cfg: cfg}
}

func readFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxFile+1))
	if err != nil {
		return nil, err
	}
	if len(data) > maxFile {
		return nil, errors.New("file is too large")
	}
	return data, nil
}

func stat(path string) (int64, time.Time, bool) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, time.Time{}, false
	}
	return st.Size(), st.ModTime(), true
}

// Gathers is how many times the sources were read (for tests).
func (e *Exporter) Gathers() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.gathers
}

// Render returns the text of the metrics. Requests inside one Interval share
// one reading of the disk.
func (e *Exporter) Render() []byte {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.cfg.Now()
	if e.body != nil && !now.Before(e.at) && now.Sub(e.at) < e.cfg.Interval {
		return e.body
	}
	e.gathers++
	e.body = e.render(now)
	e.at = now
	return e.body
}

type sample struct{ labels, value string }

type family struct {
	name, kind, help string
	samples          []sample
}

type writer struct{ families []*family }

func (w *writer) add(name, kind, help string) *family {
	f := &family{name: name, kind: kind, help: help}
	w.families = append(w.families, f)
	return f
}

func (f *family) set(labels, value string) {
	f.samples = append(f.samples, sample{labels, value})
}

// escape quotes a label value as the text format wants.
func escape(v string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v)
}

func label(name, value string) string { return name + `="` + escape(value) + `"` }

func num(v float64) string { return strconv.FormatFloat(v, 'g', -1, 64) }

func (w *writer) bytes() []byte {
	var b bytes.Buffer
	for _, f := range w.families {
		if len(f.samples) == 0 {
			continue // nothing known: the metric is not offered
		}
		sort.SliceStable(f.samples, func(i, j int) bool { return f.samples[i].labels < f.samples[j].labels })
		b.WriteString("# HELP " + f.name + " " + f.help + "\n")
		b.WriteString("# TYPE " + f.name + " " + f.kind + "\n")
		for _, s := range f.samples {
			b.WriteString(f.name)
			if s.labels != "" {
				b.WriteString("{" + s.labels + "}")
			}
			b.WriteString(" " + s.value + "\n")
		}
	}
	return b.Bytes()
}

func (e *Exporter) render(now time.Time) []byte {
	var w writer
	cfg := e.cfg

	componentUp := w.add("dpistack_component_up", "gauge", "1 if the component's process is active, 0 if it failed.")
	checkStatus := w.add("dpistack_check_status", "gauge", "Watchdog check: 0 ok, 1 warn, 2 crit.")
	if cfg.HealthFile != "" {
		if data, err := cfg.IO.ReadFile(cfg.HealthFile); err == nil {
			if rep, err := health.Parse(data); err == nil {
				for _, c := range rep.Checks {
					switch c.Status {
					case "ok":
						checkStatus.set(label("check", c.ID), "0")
					case "warn":
						checkStatus.set(label("check", c.ID), "1")
					case "crit":
						checkStatus.set(label("check", c.ID), "2")
					default:
						continue // na: no verdict, nothing to show
					}
					if id, ok := strings.CutSuffix(c.ID, ".process"); ok {
						if c.Status == "ok" {
							componentUp.set(label("component", id), "1")
						} else if c.Status == "crit" {
							componentUp.set(label("component", id), "0")
						}
					}
				}
			}
		}
	}

	packets := w.add("dpistack_suricata_kernel_packets_total", "counter", "Packets Suricata's capture saw (stats.capture.kernel_packets).")
	drops := w.add("dpistack_suricata_kernel_drops_total", "counter", "Packets the kernel dropped (stats.capture.kernel_drops).")
	ratio := w.add("dpistack_suricata_drop_ratio", "gauge", "Share of packets dropped between the last two stats events, 0 to 1.")
	uptime := w.add("dpistack_suricata_uptime_seconds", "gauge", "Suricata uptime from the newest stats event.")
	events := w.add("dpistack_eve_events_total", "counter", "Events the panel has read from eve.json since it started.")
	size := w.add("dpistack_eve_size_bytes", "gauge", "Size of eve.json.")
	age := w.add("dpistack_eve_last_event_age_seconds", "gauge", "Age of the newest event in eve.json.")
	if cfg.Eve != nil {
		// With EVE_FILE=no there is no reader and none of this is offered.
		_ = cfg.IO.Poll()
		if recent := cfg.Eve.Recent(eve.Query{Type: "stats", Limit: 2}); len(recent) > 0 {
			if cur, ok := metrics.DecodeStats(recent[0]); ok {
				packets.set("", strconv.FormatUint(cur.Packets, 10))
				drops.set("", strconv.FormatUint(cur.Drops, 10))
				uptime.set("", num(cur.Uptime))
				if len(recent) > 1 {
					if prev, ok := metrics.DecodeStats(recent[1]); ok {
						if r, ok := dropRatio(prev, cur); ok {
							ratio.set("", num(r))
						}
					}
				}
			}
		}
		for typ, n := range cfg.Eve.Counts() {
			events.set(label("event_type", typ), strconv.FormatUint(n, 10))
		}
		if cfg.EveFile != "" {
			if n, _, ok := cfg.IO.Stat(cfg.EveFile); ok {
				size.set("", strconv.FormatInt(n, 10))
			}
		}
		if ev, ok := cfg.Eve.Newest(); ok && !ev.Time.IsZero() {
			a := now.Sub(ev.Time).Seconds()
			if a < 0 {
				a = 0
			}
			age.set("", num(a))
		}
	}

	disk := w.add("dpistack_disk_free_ratio", "gauge", "Free share of the filesystem holding the path, 0 to 1.")
	seen := map[string]bool{}
	for _, p := range cfg.DiskPaths {
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		if r, ok := cfg.IO.DiskFree(p); ok {
			disk.set(label("path", p), num(r))
		}
	}

	rules := w.add("dpistack_rules_age_seconds", "gauge", "Age of suricata.rules.")
	if cfg.RulesFile != "" {
		if _, mtime, ok := cfg.IO.Stat(cfg.RulesFile); ok {
			a := now.Sub(mtime).Seconds()
			if a < 0 {
				a = 0
			}
			rules.set("", num(a))
		}
	}

	testStatus := w.add("dpistack_test_status", "gauge", "Last result of a test: 1 pass, 0 fail.")
	testTime := w.add("dpistack_test_timestamp_seconds", "gauge", "Time of the last run of a test.")
	if cfg.TestsFile != "" {
		if data, err := cfg.IO.ReadFile(cfg.TestsFile); err == nil {
			var f struct {
				Results []struct {
					Name      string `json:"name"`
					Status    string `json:"status"`
					Timestamp string `json:"timestamp"`
				} `json:"results"`
			}
			if json.Unmarshal(data, &f) == nil {
				for _, r := range f.Results {
					if r.Name == "" {
						continue
					}
					switch r.Status {
					case "pass":
						testStatus.set(label("test", r.Name), "1")
					case "fail":
						testStatus.set(label("test", r.Name), "0")
					}
					if t, err := time.Parse(time.RFC3339, r.Timestamp); err == nil {
						testTime.set(label("test", r.Name), strconv.FormatInt(t.Unix(), 10))
					}
				}
			}
		}
	}

	rss := w.add("dpistack_panel_rss_bytes", "gauge", "Resident memory of the panel.")
	if cfg.Proc != nil {
		if _, n, ok := cfg.Proc(); ok && n >= 0 {
			rss.set("", strconv.FormatInt(n, 10))
		}
	}
	return w.bytes()
}

// dropRatio is the share of packets dropped between two stats events. A
// counter that went down means Suricata restarted: there is no ratio for
// that interval, and never a negative one.
func dropRatio(prev, cur metrics.Stats) (float64, bool) {
	if cur.Packets < prev.Packets || cur.Drops < prev.Drops {
		return 0, false
	}
	dp, dd := cur.Packets-prev.Packets, cur.Drops-prev.Drops
	switch {
	case dp == 0 && dd == 0:
		return 0, true
	case dp == 0:
		return 0, false
	}
	r := float64(dd) / float64(dp)
	if r > 1 {
		r = 1
	}
	return r, true
}
