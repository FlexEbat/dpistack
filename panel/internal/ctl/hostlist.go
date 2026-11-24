package ctl

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// HostEntry is one entry of the block or allow list as
// `ips block|allow list --json` prints it.
type HostEntry struct {
	Address string `json:"address"`
	SID     int    `json:"sid"`
	Added   string `json:"added"`
	Expires string `json:"expires"`
	By      string `json:"by"`
	Note    string `json:"note"`
}

// HostAdd is what the screen sends for `ips block|allow add`. Empty means
// "not given": dpistack applies its own rules, so the CLI and the screen
// cannot differ.
type HostAdd struct {
	Kind    string // block or allow
	Address string
	Days    string
	Note    string
	By      string
}

func hostKind(kind string) error {
	if kind != "block" && kind != "allow" {
		return fmt.Errorf("ctl: ips list %q is not allowed", kind)
	}
	return nil
}

// HostList runs `ips <kind> list --json`.
func (r *Runner) HostList(ctx context.Context, kind string) ([]HostEntry, error) {
	if err := hostKind(kind); err != nil {
		return nil, err
	}
	raw, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "ips", kind, "list", "--json")
	if err != nil {
		return nil, err
	}
	var out []HostEntry
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("ctl: ips %s list: %w", kind, err)
	}
	if out == nil {
		out = []HostEntry{}
	}
	return out, nil
}

func (a HostAdd) args() []string {
	args := []string{"ips", a.Kind, "add", a.Address}
	for _, o := range []struct{ flag, value string }{
		{"--days", a.Days}, {"--note", a.Note}, {"--by", a.By},
	} {
		if o.value != "" {
			args = append(args, o.flag, o.value)
		}
	}
	if a.Days == "" {
		args = append(args, "--never")
	}
	return args
}

// HostAdd runs `ips block|allow add` and returns what it printed.
func (r *Runner) HostAdd(ctx context.Context, a HostAdd) (string, error) {
	if err := hostKind(a.Kind); err != nil {
		return "", err
	}
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, a.args()...)
	return string(out), err
}

// HostRemove runs `ips block|allow remove <address|sid>`.
func (r *Runner) HostRemove(ctx context.Context, kind, what string) error {
	if err := hostKind(kind); err != nil {
		return err
	}
	_, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "ips", kind, "remove", what)
	return err
}

// PcapTimeout bounds `pcap analyze`: Suricata gets 10 minutes itself.
const PcapTimeout = 11 * time.Minute

// PcapAnalyze runs `pcap analyze <path> --json` and returns its JSON.
func (r *Runner) PcapAnalyze(ctx context.Context, path string) ([]byte, error) {
	return r.runWith(ctx, maxOutput, PcapTimeout, nil, "pcap", "analyze", path, "--json")
}

// Report runs `report daily|weekly [--date D] --json` and returns its JSON.
func (r *Runner) Report(ctx context.Context, kind, date string) ([]byte, error) {
	if kind != "daily" && kind != "weekly" {
		return nil, fmt.Errorf("ctl: report %q is not allowed", kind)
	}
	args := []string{"report", kind}
	if date != "" {
		args = append(args, "--date", date)
	}
	args = append(args, "--json")
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, args...)
}

// Devices runs `devices --json`: the private addresses seen, newest first.
func (r *Runner) Devices(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "devices", "--json")
}
