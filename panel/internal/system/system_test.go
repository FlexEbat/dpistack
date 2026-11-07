package system

import (
	"os"
	"path/filepath"
	"testing"
)

func put(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T) *Reader {
	t.Helper()
	d := t.TempDir()
	put(t, d, "proc/uptime", "12345.67 9999.00\n")
	put(t, d, "proc/sys/kernel/hostname", "ids-gw-01\n")
	put(t, d, "proc/loadavg", "0.52 0.40 0.31 1/200 999\n")
	put(t, d, "proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 50 0 50 350 50 0 0 0 0 0\ncpu1 50 0 50 350 50 0 0 0 0 0\nintr 1\n")
	put(t, d, "proc/meminfo", "MemTotal:        8000000 kB\nMemFree:          100000 kB\nMemAvailable:    5000000 kB\nSwapTotal:       2000000 kB\nSwapFree:        1500000 kB\n")
	put(t, d, "sys/class/net/eth0/operstate", "up\n")
	put(t, d, "sys/class/net/eth0/address", "aa:bb:cc:dd:ee:ff\n")
	put(t, d, "sys/class/net/eth0/mtu", "1500\n")
	put(t, d, "sys/class/net/eth0/speed", "1000\n")
	put(t, d, "sys/class/net/eth0/device/x", "")
	put(t, d, "sys/class/net/eth0/statistics/rx_bytes", "1000\n")
	put(t, d, "sys/class/net/eth0/statistics/tx_bytes", "2000\n")
	put(t, d, "sys/class/net/eth0/statistics/rx_dropped", "7\n")
	put(t, d, "sys/class/net/lo/operstate", "unknown\n")
	put(t, d, "sys/class/net/lo/speed", "-1\n")
	put(t, d, "run/systemd/system/x", "")
	return &Reader{Proc: filepath.Join(d, "proc"), Sys: filepath.Join(d, "sys"), Run: filepath.Join(d, "run"), DockerSock: filepath.Join(d, "none.sock"), Disks: []string{d, filepath.Join(d, "missing")}}
}

func TestReadHostState(t *testing.T) {
	info := fixture(t).Read()
	if info.UptimeSeconds != 12345.67 || len(info.Load) != 3 || info.Load[0] != 0.52 {
		t.Errorf("uptime/load: %v %v", info.UptimeSeconds, info.Load)
	}
	if info.Hostname != "ids-gw-01" {
		t.Errorf("hostname = %q, want the name from proc/sys/kernel/hostname without the newline", info.Hostname)
	}
	if info.CPU.Cores != 2 {
		t.Errorf("cores = %d", info.CPU.Cores)
	}
	if info.Memory.TotalKB != 8000000 || info.Memory.AvailableKB != 5000000 || info.Memory.SwapFreeKB != 1500000 {
		t.Errorf("memory: %+v", info.Memory)
	}
	if len(info.Disks) != 1 || info.Disks[0].TotalBytes == 0 {
		t.Errorf("a missing path is skipped and a real one has a size: %+v", info.Disks)
	}
	if !info.SystemdPresent || info.DockerSocket {
		t.Errorf("systemd %v docker %v", info.SystemdPresent, info.DockerSocket)
	}
}

func TestInterfaces(t *testing.T) {
	info := fixture(t).Read()
	if len(info.Interfaces) != 2 || info.Interfaces[0].Name != "eth0" || info.Interfaces[1].Name != "lo" {
		t.Fatalf("interfaces: %+v", info.Interfaces)
	}
	eth, lo := info.Interfaces[0], info.Interfaces[1]
	if eth.SpeedMbps == nil || *eth.SpeedMbps != 1000 || eth.RxBytes != 1000 || eth.TxBytes != 2000 || eth.RxDropped != 7 || eth.Virtual || eth.MTU != 1500 {
		t.Errorf("eth0: %+v", eth)
	}
	if lo.SpeedMbps != nil || !lo.Virtual {
		t.Errorf("an interface with no speed has none, and one with no device is virtual: %+v", lo)
	}
}

func TestCPUPercentNeedsTwoSamples(t *testing.T) {
	r := fixture(t)
	if p := r.Read().CPU.Percent; p != nil {
		t.Fatalf("the first sample has no rate: %v", *p)
	}
	// 100 more busy ticks and 100 more idle ticks: 50 %.
	put(t, filepath.Dir(r.Proc), "proc/stat", "cpu  150 0 150 750 150 0 0 0 0 0\ncpu0 1 0 0 0 0 0 0 0 0 0\ncpu1 1 0 0 0 0 0 0 0 0 0\n")
	p := r.Read().CPU.Percent
	if p == nil || *p < 49.9 || *p > 50.1 {
		t.Errorf("percent = %v", p)
	}
}

func TestMissingRootsGiveEmptyFieldsNotFailure(t *testing.T) {
	info := (&Reader{Proc: "/nonexistent", Sys: "/nonexistent", Run: "/nonexistent"}).Read()
	if info.Load == nil || info.Interfaces == nil || info.Disks == nil {
		t.Errorf("lists must be empty arrays, not null: %+v", info)
	}
}

func TestPathsOnOneFilesystemAreOneDisk(t *testing.T) {
	r := fixture(t)
	sub := filepath.Join(filepath.Dir(r.Proc), "sub")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	r.Disks = []string{filepath.Dir(r.Proc), sub}
	got := r.Read().Disks
	if len(got) != 1 || got[0].Path != filepath.Dir(r.Proc) {
		t.Errorf("disks: %+v", got)
	}
}

func TestMissingHostnameIsEmptyNotFailure(t *testing.T) {
	r := fixture(t)
	if err := os.Remove(filepath.Join(r.Proc, "sys", "kernel", "hostname")); err != nil {
		t.Fatal(err)
	}
	if got := r.Read().Hostname; got != "" {
		t.Errorf("hostname = %q, want empty", got)
	}
}
