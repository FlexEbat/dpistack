package ctl

import (
	"context"
	"fmt"
	"strconv"
)

// The Alert Center (tech.md 18.43). Each method runs one `alerts` verb and
// returns the JSON it printed, unchanged. The caller has checked the values
// against the same patterns as the verb.

// AlertsList runs `alerts list --json`; an empty filter is left out.
func (r *Runner) AlertsList(ctx context.Context, state, source, severity string) ([]byte, error) {
	args := []string{"alerts", "list", "--json"}
	for _, f := range [][2]string{{"--state", state}, {"--source", source}, {"--severity", severity}} {
		if f[1] != "" {
			args = append(args, f[0], f[1])
		}
	}
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, args...)
}

// AlertsHistory runs `alerts history --json`; limit 0 means the default.
func (r *Runner) AlertsHistory(ctx context.Context, limit int) ([]byte, error) {
	args := []string{"alerts", "history", "--json"}
	if limit > 0 {
		args = append(args, "--limit", strconv.Itoa(limit))
	}
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, args...)
}

// AlertsAct runs `alerts ack|snooze|resolve|reopen <key>`; by is the panel
// user, so the state names who decided, not the account of the panel.
func (r *Runner) AlertsAct(ctx context.Context, action, key, dur, note, by string) ([]byte, error) {
	switch action {
	case "ack", "snooze", "resolve", "reopen":
	default:
		return nil, fmt.Errorf("ctl: unknown alerts action %q", action)
	}
	args := []string{"alerts", action, key}
	if dur != "" {
		args = append(args, "--for", dur)
	}
	if note != "" {
		args = append(args, "--note", note)
	}
	if by != "" {
		args = append(args, "--by", by)
	}
	return r.runWith(ctx, maxOutput, writeTimeout, nil, args...)
}
