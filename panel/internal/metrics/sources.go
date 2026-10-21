package metrics

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/eve"
)

// DecodeStats reads the counters out of one `stats` event.
//
// Suricata in NFQUEUE mode (IPS) has no `stats.capture` block at all (checked
// against Suricata 7.0.3 with a real queue): the packets it saw are in
// `stats.decoder.pkts`, and there is no kernel drop counter. Such an event
// gives Packets from the decoder and NoKernel set, so a drop count of zero is
// never invented.
func DecodeStats(ev eve.Event) (Stats, bool) {
	var e struct {
		Stats struct {
			Uptime  float64 `json:"uptime"`
			Capture *struct {
				Packets uint64 `json:"kernel_packets"`
				Drops   uint64 `json:"kernel_drops"`
			} `json:"capture"`
			Decoder struct {
				Pkts uint64 `json:"pkts"`
			} `json:"decoder"`
		} `json:"stats"`
	}
	if err := json.Unmarshal(ev.Line, &e); err != nil {
		return Stats{}, false
	}
	st := Stats{ID: ev.ID, Uptime: e.Stats.Uptime, Time: ev.Time}
	if c := e.Stats.Capture; c != nil {
		st.Packets, st.Drops = c.Packets, c.Drops
	} else {
		st.Packets, st.NoKernel = e.Stats.Decoder.Pkts, true
	}
	return st, true
}

// EveStats returns the newest `stats` event of r as Stats. It polls the
// file first, so the numbers are as fresh as the file.
func EveStats(r *eve.Reader) func() (Stats, bool) {
	return func() (Stats, bool) {
		if err := r.Poll(); err != nil {
			return Stats{}, false
		}
		last := r.Recent(eve.Query{Type: "stats", Limit: 1})
		if len(last) == 0 {
			return Stats{}, false
		}
		return DecodeStats(last[0])
	}
}

// FileSize returns the size of path; a file that is not there is unknown,
// not zero.
func FileSize(path string) func() (int64, bool) {
	return func() (int64, bool) {
		st, err := os.Stat(path)
		if err != nil {
			return 0, false
		}
		return st.Size(), true
	}
}

// FreeRatio is the free share (0..1) of the filesystem that holds dir
// (statfs, as tech.md 3 allows).
func FreeRatio(dir string) (float64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil || st.Blocks == 0 {
		return 0, false
	}
	return float64(st.Bavail) / float64(st.Blocks), true
}

// DiskFree returns the free share of the filesystem that holds path's
// directory.
func DiskFree(path string) func() (float64, bool) {
	dir := filepath.Dir(path)
	return func() (float64, bool) { return FreeRatio(dir) }
}

// Proc reports the CPU time and the resident memory of this process.
func Proc() (time.Duration, int64, bool) {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return 0, 0, false
	}
	cpu := time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
	return cpu, rss(), true
}

// rss reads the resident pages from /proc/self/statm; -1 if that fails, so
// the point is unknown rather than zero.
func rss() int64 {
	data, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return -1
	}
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return -1
	}
	pages, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil {
		return -1
	}
	return pages * int64(os.Getpagesize())
}
