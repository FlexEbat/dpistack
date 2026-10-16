package metrics

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"time"
)

// fileVersion is bumped when the layout of metrics.json changes; a file of
// another version is ignored.
const fileVersion = 1

// file is metrics.json: one row per sample, [time, v0, v1, ...] with null
// for a value that was not known.
type file struct {
	Version int          `json:"version"`
	Step    int          `json:"step_seconds"`
	Saved   int64        `json:"saved"`
	Samples [][]*float64 `json:"samples"`
}

// Save writes the ring to metrics.json.
//
// The installer creates the file for the panel user and nothing else in the
// state directory is writable by it, so the file is rewritten in place:
// new content first, then the length is cut. A crash in the middle leaves a
// file load rejects, which costs history, not correctness.
func (c *Collector) Save() error {
	if c.cfg.File == "" {
		return nil
	}
	c.mu.Lock()
	f := file{Version: fileVersion, Step: int(c.cfg.Step / time.Second), Saved: c.cfg.Now().Unix()}
	f.Samples = make([][]*float64, len(c.ring))
	for i, s := range c.ring {
		row := make([]*float64, 1+int(numSeries))
		t := float64(s.T)
		row[0] = &t
		for j, v := range s.V {
			if !math.IsNaN(v) {
				v := v
				row[1+j] = &v
			}
		}
		f.Samples[i] = row
	}
	c.mu.Unlock()

	data, err := json.Marshal(f)
	if err != nil {
		return err
	}
	out, err := os.OpenFile(c.cfg.File, os.O_WRONLY|os.O_CREATE, 0o640)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := out.WriteAt(data, 0); err != nil {
		return err
	}
	if err := out.Truncate(int64(len(data))); err != nil {
		return err
	}
	return out.Sync()
}

// load reads metrics.json and keeps what is still inside the 24-hour
// window, oldest first and at most Capacity. A missing, empty, foreign or
// damaged file gives an empty ring.
func load(path string, now time.Time, logf func(string, ...any)) []Sample {
	data, err := os.ReadFile(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			logf("metrics: cannot read %s: %v", path, err)
		}
		return nil
	}
	if len(data) == 0 {
		return nil
	}
	var f file
	if err := json.Unmarshal(data, &f); err != nil || f.Version != fileVersion {
		logf("metrics: %s is not usable, starting empty", path)
		return nil
	}
	oldest := now.Add(-Window).Unix()
	var ring []Sample
	var last int64
	for _, row := range f.Samples {
		if len(row) != 1+int(numSeries) || row[0] == nil {
			continue
		}
		t := int64(*row[0])
		if t < oldest || t > now.Unix() || t <= last {
			continue // too old, from the future, or out of order
		}
		s := Sample{T: t}
		for j := range s.V {
			s.V[j] = nan()
			if v := row[1+j]; v != nil && !math.IsNaN(*v) && !math.IsInf(*v, 0) {
				s.V[j] = *v
			}
		}
		ring = append(ring, s)
		last = t
	}
	if len(ring) > Capacity {
		ring = ring[len(ring)-Capacity:]
	}
	return ring
}
