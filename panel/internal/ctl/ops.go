package ctl

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// TestTimeout bounds `test all`: an offline BitTorrent check, then an HTTPS
// request (curl --max-time 15) and the wait for its event.
const TestTimeout = 3 * time.Minute

// IfaceTimeout bounds `iface add|remove`, which runs reconfigure.
const IfaceTimeout = 3 * time.Minute

// TestRun runs `test <which> --json` and returns its stdout. A test that
// failed makes ctl exit 1 but still print the results; that is an
// *ExitError whose Output holds them, and the caller decides.
func (r *Runner) TestRun(ctx context.Context, which string) ([]byte, error) {
	switch which {
	case "bittorrent", "https", "all":
	default:
		return nil, fmt.Errorf("ctl: test %q is not allowed", which)
	}
	return r.runWith(ctx, maxOutput, TestTimeout, nil, "test", which, "--json")
}

// IfaceList runs `iface list`: the interfaces in IFACES, one per line.
func (r *Runner) IfaceList(ctx context.Context) ([]string, error) {
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "iface", "list")
	if err != nil {
		return nil, err
	}
	names := []string{}
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			names = append(names, line)
		}
	}
	return names, nil
}

// IfaceChange runs `iface add|remove <name>`.
func (r *Runner) IfaceChange(ctx context.Context, verb, name string) (string, error) {
	if verb != "add" && verb != "remove" {
		return "", fmt.Errorf("ctl: iface verb %q is not allowed", verb)
	}
	out, err := r.runWith(ctx, maxOutput, IfaceTimeout, nil, "iface", verb, name)
	return strings.TrimSpace(string(out)), err
}

// ModeTimeout bounds `mode ids|ips`: it runs reconfigure, which restarts
// Suricata, and then the iptables rules.
const ModeTimeout = 3 * time.Minute

// Bounds of --confirm-timeout, the same as dpistack-ctl enforces.
const (
	ModeConfirmMin = 10
	ModeConfirmMax = 3600
)

// ModeState is `mode status --json`: the current mode, the IPS method and,
// while a switch to ips waits for its confirmation, the seconds left before
// ctl takes it back.
type ModeState struct {
	Mode         string `json:"mode"`
	Method       string `json:"method"`
	Pending      bool   `json:"pending"`
	RemainingSec int    `json:"remaining_sec"`
}

// ModeStatus runs `mode status --json`.
func (r *Runner) ModeStatus(ctx context.Context) (ModeState, error) {
	out, err := r.runWith(ctx, maxOutput, callTimeout, nil, "mode", "status", "--json")
	if err != nil {
		return ModeState{}, err
	}
	var st ModeState
	if err := json.Unmarshal(out, &st); err != nil || (st.Mode != "ids" && st.Mode != "ips") {
		return ModeState{}, fmt.Errorf("%w: mode status: %q", ErrUnavailable, strings.TrimSpace(string(out)))
	}
	return st, nil
}

// ModeSet runs `mode ids|ips [--confirm-timeout N]`; confirmTimeout 0 leaves
// the default of ctl.
func (r *Runner) ModeSet(ctx context.Context, mode string, confirmTimeout int) (string, error) {
	if mode != "ids" && mode != "ips" {
		return "", fmt.Errorf("ctl: mode %q is not allowed", mode)
	}
	args := []string{"mode", mode}
	if mode == "ips" && confirmTimeout != 0 {
		if confirmTimeout < ModeConfirmMin || confirmTimeout > ModeConfirmMax {
			return "", fmt.Errorf("ctl: confirm timeout %d is out of range", confirmTimeout)
		}
		args = append(args, "--confirm-timeout", strconv.Itoa(confirmTimeout))
	}
	out, err := r.runWith(ctx, maxOutput, ModeTimeout, nil, args...)
	return strings.TrimSpace(string(out)), err
}

// ModeConfirm runs `mode-confirm`.
func (r *Runner) ModeConfirm(ctx context.Context) (string, error) {
	out, err := r.runWith(ctx, maxOutput, callTimeout, nil, "mode-confirm")
	return strings.TrimSpace(string(out)), err
}
