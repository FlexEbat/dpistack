package ctl

import (
	"context"
	"fmt"
	"strings"
)

// The read side of Rules v2 (tech.md 18.41). Each method runs one verb and
// returns the JSON it printed, unchanged: the numbers on the screen are the
// numbers of `dpistack rules-stats` in the CLI, not a second computation.

// RulesStats runs `rules-stats --json`.
func (r *Runner) RulesStats(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-stats", "--json")
}

// RulesHistory runs `rules-history --json`.
func (r *Runner) RulesHistory(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-history", "--json")
}

// RulesDescribe runs `rules-describe <sid>...`; the caller has checked that
// every sid is a number and that there are at most 20.
func (r *Runner) RulesDescribe(ctx context.Context, sids []string) ([]byte, error) {
	if len(sids) == 0 || len(sids) > 20 {
		return nil, fmt.Errorf("ctl: rules-describe takes 1 to 20 sids")
	}
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, append([]string{"rules-describe"}, sids...)...)
}

// RulesLocalCheck runs `rules-local check` with the candidate file on stdin.
// It takes as long as config-write, because it runs `suricata -T`.
func (r *Runner) RulesLocalCheck(ctx context.Context, content []byte) ([]byte, error) {
	return r.runWith(ctx, maxOutput, writeTimeout, content, "rules-local", "check")
}

// ConfigHistory runs `config-history <name>`: the saved versions of a file.
func (r *Runner) ConfigHistory(ctx context.Context, name string) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "config-history", name)
}

// ConfigVersion runs `config-history <name> <id>`: the content of one version.
func (r *Runner) ConfigVersion(ctx context.Context, name, id string) (string, error) {
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "config-history", name, id)
	return strings.TrimRight(string(out), "\n") + "\n", err
}

// RulesFindOptions are the filters of `rules-find`; an empty one is not sent.
type RulesFindOptions struct {
	Class  string
	Source string
	State  string
	Text   string
}

// RulesFind runs `rules-find` with the filters given.
func (r *Runner) RulesFind(ctx context.Context, o RulesFindOptions) ([]byte, error) {
	args := []string{"rules-find"}
	for _, f := range []struct{ flag, value string }{{"--class", o.Class}, {"--source", o.Source}, {"--state", o.State}, {"--text", o.Text}} {
		if f.value != "" {
			args = append(args, f.flag, f.value)
		}
	}
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, args...)
}

// RulesFacets runs `rules-facets`: the categories and sources the filters offer.
func (r *Runner) RulesFacets(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-facets")
}
