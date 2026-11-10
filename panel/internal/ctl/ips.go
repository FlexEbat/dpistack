package ctl

import (
	"context"
	"fmt"
	"strings"
)

// The IPS page (tech.md 18.42). Each method runs one verb and returns the
// JSON it printed, unchanged: the page shows the numbers of
// `dpistack ips status`, not a second computation.

// IPSStatus runs `ips status --json`.
func (r *Runner) IPSStatus(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "ips", "status", "--json")
}

// IPSTest runs `ips test --json [--sid ...] [--pcap ...]`. The caller has
// checked that the sids are numbers (20 at most) and the pcap a short word.
// With the whole drop rule set the engine loads thousands of rules, so it
// gets the allowance of config-write.
func (r *Runner) IPSTest(ctx context.Context, sids []string, pcap string) ([]byte, error) {
	if len(sids) > 20 {
		return nil, fmt.Errorf("ctl: ips test takes 20 sids at most")
	}
	args := []string{"ips", "test", "--json"}
	if len(sids) > 0 {
		args = append(args, "--sid", strings.Join(sids, ","))
	}
	if pcap != "" {
		args = append(args, "--pcap", pcap)
	}
	return r.runWith(ctx, maxOutput, writeTimeout, nil, args...)
}
