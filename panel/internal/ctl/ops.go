package ctl

import (
	"context"
	"fmt"
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
