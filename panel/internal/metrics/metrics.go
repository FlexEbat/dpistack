// Package metrics keeps the series behind the Metrics screen: a ring of the
// last 24 hours at 30-second steps, restored from metrics.json after a
// restart.
//
// A point that cannot be known is NaN in memory and null on the wire, never
// zero: a graph of zero drops and a graph with no data say different things.
package metrics

import (
	"context"
	"fmt"
	"math"
	"sync"
	"time"
)

const (
	Step      = 30 * time.Second
	Window    = 24 * time.Hour
	Capacity  = int(Window / Step) // 2880 samples
	SaveEvery = time.Hour
)

// Series indexes the values of a Sample.
type Series int

const (
	PPS     Series = iota // packets per second seen by Suricata (stats)
	Drops                 // packets per second the kernel dropped (stats)
	CPU                   // CPU of the panel process, percent of one core
	RSS                   // resident memory of the panel process, bytes
	EveSize               // size of eve.json, bytes
	Disk                  // free share (0..1) of the filesystem holding eve.json
	numSeries
)

// Names and Units are the API names of the series and their units.
var (
	Names = [numSeries]string{"pps", "drops", "cpu", "rss", "eve_size", "disk"}
	Units = [numSeries]string{"packets/s", "packets/s", "percent", "bytes", "bytes", "ratio"}
)

// Sample is one tick: the time (unix seconds) and a value per series.
type Sample struct {
	T int64
	V [numSeries]float64
}

// Stats is the newest `stats` event: the cumulative counters of Suricata.
type Stats struct {
	ID      uint64    // grows with every stats event
	Packets uint64    // stats.capture.kernel_packets
	Drops   uint64    // stats.capture.kernel_drops
	Uptime  float64   // stats.uptime, seconds; 0 if absent
	Time    time.Time // timestamp of the event
	// NoKernel: the event has no stats.capture (Suricata in NFQUEUE mode).
	// Packets is then stats.decoder.pkts and Drops is not known.
	NoKernel bool
}

// Inputs is where the values come from. A nil function means the source is
// off for good: with EVE_FILE=no there is no Stats, EveSize or DiskFree.
type Inputs struct {
	Stats    func() (Stats, bool)
	EveSize  func() (int64, bool)
	DiskFree func() (float64, bool)
	Proc     func() (cpu time.Duration, rss int64, ok bool) // rss < 0: unknown
}

// Config builds a Collector.
type Config struct {
	Inputs
	Now  func() time.Time // nil means time.Now
	File string           // metrics.json; empty means nothing is saved
	Step time.Duration    // zero means Step; tests use a short one
	Logf func(format string, args ...any)
}

// Collector samples the inputs and answers range queries.
type Collector struct {
	cfg Config

	mu        sync.Mutex
	ring      []Sample
	prevStats Stats
	havePrev  bool
	statsSeen bool
	prevCPU   time.Duration
	prevWall  time.Time
	haveCPU   bool
}

// New returns a Collector holding what metrics.json had of the last 24 hours.
func New(cfg Config) *Collector {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.Step <= 0 {
		cfg.Step = Step
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	c := &Collector{cfg: cfg}
	if cfg.File != "" {
		c.ring = load(cfg.File, cfg.Now(), cfg.Logf)
	}
	return c
}

func nan() float64 { return math.NaN() }

// Sample takes one tick. Counters of Suricata are cumulative, so a rate
// needs the previous stats event; a value that went down means Suricata
// restarted, and that interval is skipped instead of drawn as a negative.
func (c *Collector) Sample() {
	now := c.cfg.Now()
	s := Sample{T: now.Unix()}
	for i := range s.V {
		s.V[i] = nan()
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.cfg.Stats != nil {
		if cur, ok := c.cfg.Stats(); ok {
			c.statsSeen = true
			c.rate(&s, cur)
		}
	}
	if c.cfg.Proc != nil {
		if cpu, rss, ok := c.cfg.Proc(); ok {
			if rss >= 0 {
				s.V[RSS] = float64(rss)
			}
			if c.haveCPU {
				if wall := now.Sub(c.prevWall).Seconds(); wall > 0 && cpu >= c.prevCPU {
					s.V[CPU] = (cpu - c.prevCPU).Seconds() / wall * 100
				}
			}
			c.prevCPU, c.prevWall, c.haveCPU = cpu, now, true
		}
	}
	if c.cfg.EveSize != nil {
		if size, ok := c.cfg.EveSize(); ok {
			s.V[EveSize] = float64(size)
		}
	}
	if c.cfg.DiskFree != nil {
		if free, ok := c.cfg.DiskFree(); ok {
			s.V[Disk] = free
		}
	}

	c.ring = append(c.ring, s)
	if len(c.ring) > Capacity {
		c.ring = append(c.ring[:0], c.ring[len(c.ring)-Capacity:]...)
	}
}

// rate fills PPS and Drops from the change since the previous stats event.
func (c *Collector) rate(s *Sample, cur Stats) {
	prev, had := c.prevStats, c.havePrev
	if had && cur.ID == prev.ID {
		return // no new stats event since the last tick
	}
	c.prevStats, c.havePrev = cur, true
	if !had {
		return
	}
	if cur.Packets < prev.Packets || cur.Drops < prev.Drops || (cur.Uptime > 0 && cur.Uptime < prev.Uptime) {
		return // counters were reset: skip this interval
	}
	dt := cur.Time.Sub(prev.Time).Seconds()
	if cur.Uptime > 0 && prev.Uptime > 0 {
		dt = cur.Uptime - prev.Uptime
	}
	if dt <= 0 {
		return
	}
	s.V[PPS] = float64(cur.Packets-prev.Packets) / dt
	if !cur.NoKernel {
		s.V[Drops] = float64(cur.Drops-prev.Drops) / dt
	}
}

// Run samples every step until ctx ends, saves every SaveEvery and once more
// on the way out.
func (c *Collector) Run(ctx context.Context) {
	c.Sample()
	tick := time.NewTicker(c.cfg.Step)
	defer tick.Stop()
	lastSave := c.cfg.Now()
	for {
		select {
		case <-ctx.Done():
			c.save()
			return
		case <-tick.C:
			c.Sample()
			if now := c.cfg.Now(); now.Sub(lastSave) >= SaveEvery {
				c.save()
				lastSave = now
			}
		}
	}
}

func (c *Collector) save() {
	if err := c.Save(); err != nil {
		c.cfg.Logf("metrics: cannot save %s: %v", c.cfg.File, err)
	}
}

// available says whether a series can have values at all, and if not, why.
func (c *Collector) available(i Series) (bool, string) {
	switch i {
	case PPS, Drops:
		if c.cfg.Stats == nil {
			return false, "просмотр событий выключен (EVE_FILE=no)"
		}
		if !c.statsSeen {
			return false, "в eve.json нет событий stats: добавьте stats в EVE_TYPES"
		}
	case EveSize, Disk:
		if (i == EveSize && c.cfg.EveSize == nil) || (i == Disk && c.cfg.DiskFree == nil) {
			return false, "просмотр событий выключен (EVE_FILE=no)"
		}
	case CPU, RSS:
		if c.cfg.Proc == nil {
			return false, "нет данных о процессе панели"
		}
	}
	return true, ""
}

// SeriesOut is one series of an answer.
type SeriesOut struct {
	Unit      string     `json:"unit"`
	Available bool       `json:"available"`
	Reason    string     `json:"reason,omitempty"`
	Values    []*float64 `json:"values"`
}

// Result is the answer to a range query: every series on one time grid,
// Values[k] covering [Start+k*Step, Start+(k+1)*Step), the last one ending
// at the second of the query.
type Result struct {
	Range  string               `json:"range"`
	Start  int64                `json:"start"`
	Step   int                  `json:"step"`
	Series map[string]SeriesOut `json:"series"`
}

// ranges are the periods the screen may ask for and the grid of each. The
// grids keep an answer near 180 points; the finer data stays in the ring.
var ranges = map[string]struct{ span, step time.Duration }{
	"1h":  {time.Hour, 30 * time.Second},
	"6h":  {6 * time.Hour, 2 * time.Minute},
	"24h": {24 * time.Hour, 8 * time.Minute},
}

// Query answers GET /api/metrics?range=. A bucket with several samples is
// their mean over the samples that have a value; with none it is null.
func (c *Collector) Query(rng string) (Result, error) {
	spec, ok := ranges[rng]
	if !ok {
		return Result{}, fmt.Errorf("range: 1h, 6h or 24h")
	}
	now := c.cfg.Now()
	n := int(spec.span / spec.step)
	// The grid covers (now-span, now]: a sample taken at this very second
	// belongs to the last bucket on its own, not squeezed into it.
	start := now.Unix() - int64(spec.span/time.Second) + 1
	step := int64(spec.step / time.Second)

	c.mu.Lock()
	defer c.mu.Unlock()
	res := Result{Range: rng, Start: start, Step: int(step), Series: map[string]SeriesOut{}}
	for i := Series(0); i < numSeries; i++ {
		sum := make([]float64, n)
		cnt := make([]int, n)
		for _, s := range c.ring {
			if s.T < start || s.T > now.Unix() || math.IsNaN(s.V[i]) {
				continue
			}
			k := int((s.T - start) / step)
			if k >= n {
				continue
			}
			sum[k] += s.V[i]
			cnt[k]++
		}
		values := make([]*float64, n)
		for k := range values {
			if cnt[k] > 0 {
				v := sum[k] / float64(cnt[k])
				values[k] = &v
			}
		}
		avail, reason := c.available(i)
		res.Series[Names[i]] = SeriesOut{Unit: Units[i], Available: avail, Reason: reason, Values: values}
	}
	return res, nil
}

// Len is the number of samples in the ring.
func (c *Collector) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.ring)
}
