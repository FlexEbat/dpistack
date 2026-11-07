// Package system reads the state of the host for the Overview and the
// interface page (slice 38): load, CPU, memory, disks, uptime and the
// network interfaces with their speed and counters. Everything comes from
// /proc, /sys and statfs; nothing is run. The roots are fields so the tests
// can point them at a directory.
package system

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// Iface is one network interface. Speed is in Mbit/s and nil when the
// interface does not report one (a bridge, a veth, a down link).
type Iface struct {
	Name      string `json:"name"`
	State     string `json:"state"`
	MAC       string `json:"mac,omitempty"`
	MTU       int    `json:"mtu,omitempty"`
	SpeedMbps *int   `json:"speed_mbps"`
	RxBytes   uint64 `json:"rx_bytes"`
	TxBytes   uint64 `json:"tx_bytes"`
	RxPackets uint64 `json:"rx_packets"`
	TxPackets uint64 `json:"tx_packets"`
	RxErrors  uint64 `json:"rx_errors"`
	TxErrors  uint64 `json:"tx_errors"`
	RxDropped uint64 `json:"rx_dropped"`
	TxDropped uint64 `json:"tx_dropped"`
	Virtual   bool   `json:"virtual"`
	Capture   *bool  `json:"capture,omitempty"` // set by the caller: is it in IFACES
}

type Memory struct {
	TotalKB     uint64 `json:"total_kb"`
	AvailableKB uint64 `json:"available_kb"`
	SwapTotalKB uint64 `json:"swap_total_kb"`
	SwapFreeKB  uint64 `json:"swap_free_kb"`
}

type Disk struct {
	Path       string `json:"path"`
	TotalBytes uint64 `json:"total_bytes"`
	FreeBytes  uint64 `json:"free_bytes"`
}

type CPU struct {
	Cores int `json:"cores"`
	// Percent is the busy share since the previous call; nil on the first
	// call, because one sample says nothing about a rate.
	Percent *float64 `json:"percent"`
}

type Info struct {
	Hostname       string    `json:"hostname"`
	UptimeSeconds  float64   `json:"uptime_seconds"`
	Load           []float64 `json:"load"`
	CPU            CPU       `json:"cpu"`
	Memory         Memory    `json:"memory"`
	Disks          []Disk    `json:"disks"`
	Interfaces     []Iface   `json:"interfaces"`
	SystemdPresent bool      `json:"systemd_present"`
	DockerSocket   bool      `json:"docker_socket"`
}

// Reader holds the roots and the previous CPU sample.
type Reader struct {
	Proc, Sys  string   // /proc and /sys
	Run        string   // /run, for the systemd marker
	DockerSock string   // the docker socket
	Disks      []string // the paths whose free space is reported
	Cores      func() int

	mu        sync.Mutex
	prevBusy  uint64
	prevTotal uint64
	havePrev  bool
}

// NewReader reads the real host.
func NewReader(disks []string) *Reader {
	return &Reader{Proc: "/proc", Sys: "/sys", Run: "/run", DockerSock: "/var/run/docker.sock", Disks: disks}
}

func readFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func readUint(path string) uint64 {
	n, _ := strconv.ParseUint(readFile(path), 10, 64)
	return n
}

// Read collects one snapshot. A source that cannot be read leaves its
// fields at zero or empty; the caller decides what is worth saying.
func (r *Reader) Read() Info {
	info := Info{Load: []float64{}, Disks: []Disk{}, Interfaces: []Iface{}}
	info.Hostname = strings.TrimSpace(readFile(filepath.Join(r.Proc, "sys", "kernel", "hostname")))
	if f := strings.Fields(readFile(filepath.Join(r.Proc, "uptime"))); len(f) > 0 {
		info.UptimeSeconds, _ = strconv.ParseFloat(f[0], 64)
	}
	if f := strings.Fields(readFile(filepath.Join(r.Proc, "loadavg"))); len(f) >= 3 {
		for _, s := range f[:3] {
			v, _ := strconv.ParseFloat(s, 64)
			info.Load = append(info.Load, v)
		}
	}
	info.CPU = r.cpu()
	info.Memory = r.memory()
	seen := map[syscall.Fsid]bool{}
	for _, p := range r.Disks {
		var st syscall.Statfs_t
		if err := syscall.Statfs(p, &st); err != nil {
			continue
		}
		// Two paths on one filesystem are one disk: the first one is shown.
		if seen[st.Fsid] {
			continue
		}
		seen[st.Fsid] = true
		bs := uint64(st.Bsize)
		info.Disks = append(info.Disks, Disk{Path: p, TotalBytes: st.Blocks * bs, FreeBytes: st.Bavail * bs})
	}
	info.Interfaces = r.interfaces()
	_, err := os.Stat(filepath.Join(r.Run, "systemd", "system"))
	info.SystemdPresent = err == nil
	if r.DockerSock != "" {
		_, err = os.Stat(r.DockerSock)
		info.DockerSocket = err == nil
	}
	return info
}

// cpu counts the cores from /proc/stat and the busy share from the change
// of the "cpu" line since the last call (iowait counts as idle).
func (r *Reader) cpu() CPU {
	c := CPU{}
	f, err := os.Open(filepath.Join(r.Proc, "stat"))
	if err != nil {
		return c
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	var total, idle uint64
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 0 || !strings.HasPrefix(fields[0], "cpu") {
			continue
		}
		if fields[0] != "cpu" {
			c.Cores++
			continue
		}
		for i, s := range fields[1:] {
			v, _ := strconv.ParseUint(s, 10, 64)
			if i >= 8 { // guest times are already inside user and nice
				break
			}
			total += v
			if i == 3 || i == 4 {
				idle += v
			}
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	busy := total - idle
	if r.havePrev && total > r.prevTotal {
		p := float64(busy-r.prevBusy) / float64(total-r.prevTotal) * 100
		if p < 0 {
			p = 0
		}
		c.Percent = &p
	}
	r.prevBusy, r.prevTotal, r.havePrev = busy, total, true
	return c
}

func (r *Reader) memory() Memory {
	var m Memory
	f, err := os.Open(filepath.Join(r.Proc, "meminfo"))
	if err != nil {
		return m
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		key, rest, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		v, _ := strconv.ParseUint(fields[0], 10, 64)
		switch key {
		case "MemTotal":
			m.TotalKB = v
		case "MemAvailable":
			m.AvailableKB = v
		case "SwapTotal":
			m.SwapTotalKB = v
		case "SwapFree":
			m.SwapFreeKB = v
		}
	}
	return m
}

func (r *Reader) interfaces() []Iface {
	base := filepath.Join(r.Sys, "class", "net")
	entries, err := os.ReadDir(base)
	if err != nil {
		return []Iface{}
	}
	out := []Iface{}
	for _, e := range entries {
		name := e.Name()
		dir := filepath.Join(base, name)
		i := Iface{Name: name, State: readFile(filepath.Join(dir, "operstate")), MAC: readFile(filepath.Join(dir, "address"))}
		i.MTU = int(readUint(filepath.Join(dir, "mtu")))
		// A link with no speed reads -1 or fails with EINVAL.
		if v, err := strconv.Atoi(readFile(filepath.Join(dir, "speed"))); err == nil && v > 0 {
			i.SpeedMbps = &v
		}
		st := filepath.Join(dir, "statistics")
		i.RxBytes, i.TxBytes = readUint(filepath.Join(st, "rx_bytes")), readUint(filepath.Join(st, "tx_bytes"))
		i.RxPackets, i.TxPackets = readUint(filepath.Join(st, "rx_packets")), readUint(filepath.Join(st, "tx_packets"))
		i.RxErrors, i.TxErrors = readUint(filepath.Join(st, "rx_errors")), readUint(filepath.Join(st, "tx_errors"))
		i.RxDropped, i.TxDropped = readUint(filepath.Join(st, "rx_dropped")), readUint(filepath.Join(st, "tx_dropped"))
		// A real device has a "device" link; lo, bridges, veth and tunnels do not.
		_, derr := os.Stat(filepath.Join(dir, "device"))
		i.Virtual = derr != nil
		out = append(out, i)
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Name < out[b].Name })
	return out
}
