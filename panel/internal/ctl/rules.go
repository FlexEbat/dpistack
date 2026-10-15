package ctl

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// rulesTimeout bounds the quick rules calls. Editing enable.conf and
// disable.conf waits up to 30 seconds for the installer lock (4.5), so the
// bound is longer than callTimeout.
const rulesTimeout = 45 * time.Second

// UpdateTimeout bounds `rules-update`: it downloads the rule sets, merges
// them, runs `suricata -T` on the result and reloads.
const UpdateTimeout = 5 * time.Minute

// Source is one rule source as `suricata-update` lists it.
type Source struct {
	Name    string `json:"name"`
	Vendor  string `json:"vendor"`
	Summary string `json:"summary"`
	License string `json:"license"`
	Enabled bool   `json:"enabled"`
	// Custom is a source that is enabled but absent from the index, such as
	// one added by URL.
	Custom bool `json:"custom"`
}

// Rule is one search hit.
type Rule struct {
	SID string `json:"sid"`
	Msg string `json:"msg"`
}

// MaxSearchResults is the limit dpistack-ctl applies to rules-search (4.5);
// the panel enforces it again so a changed helper cannot flood the screen.
const MaxSearchResults = 50

// RulesSources runs `rules-sources list` and `rules-sources list --enabled`
// and merges them. suricata-update prints the enabled state only in the
// second listing.
func (r *Runner) RulesSources(ctx context.Context) ([]Source, error) {
	all, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-sources", "list")
	if err != nil {
		return nil, err
	}
	enabled, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-sources", "list", "--enabled")
	if err != nil {
		return nil, err
	}
	return mergeSources(parseSources(string(all)), parseEnabled(string(enabled))), nil
}

// RulesSource runs `rules-sources enable|disable|remove <name>` or
// `rules-sources add-url <url>`.
func (r *Runner) RulesSource(ctx context.Context, action, arg string) (string, error) {
	switch action {
	case "enable", "disable", "remove", "add-url":
	default:
		return "", fmt.Errorf("ctl: rules-sources action %q is not allowed", action)
	}
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-sources", action, arg)
	return strings.TrimSpace(string(out)), err
}

// RulesGroup runs `rules-group enable|disable <group>`.
func (r *Runner) RulesGroup(ctx context.Context, verb, group string) (string, error) {
	if verb != "enable" && verb != "disable" {
		return "", fmt.Errorf("ctl: rules-group verb %q is not allowed", verb)
	}
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-group", verb, group)
	return strings.TrimSpace(string(out)), err
}

// RulesSID runs `rules-sid enable|disable <sid>`.
func (r *Runner) RulesSID(ctx context.Context, verb, sid string) (string, error) {
	if verb != "enable" && verb != "disable" {
		return "", fmt.Errorf("ctl: rules-sid verb %q is not allowed", verb)
	}
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-sid", verb, sid)
	return strings.TrimSpace(string(out)), err
}

// RulesSearch runs `rules-search <q>` and returns at most MaxSearchResults
// rules.
func (r *Runner) RulesSearch(ctx context.Context, q string) ([]Rule, error) {
	out, err := r.runWith(ctx, maxOutput, rulesTimeout, nil, "rules-search", q)
	if err != nil {
		return nil, err
	}
	rules := []Rule{}
	for _, line := range strings.Split(string(out), "\n") {
		sid, msg, ok := strings.Cut(strings.TrimRight(line, "\r"), "\t")
		if !ok || sid == "" {
			continue
		}
		rules = append(rules, Rule{SID: sid, Msg: msg})
		if len(rules) == MaxSearchResults {
			break
		}
	}
	return rules, nil
}

// RulesUpdate runs `rules-update` and returns what suricata-update and the
// checks said. A failed update is an *ExitError whose Output holds the
// reason and whose exit code is 1; ctl has put the previous ruleset back.
func (r *Runner) RulesUpdate(ctx context.Context) (string, error) {
	out, err := r.runWith(ctx, maxOutput, UpdateTimeout, nil, "rules-update")
	return strings.TrimSpace(string(out)), err
}

// ansi matches the colour codes suricata-update prints even when its output
// is not a terminal.
var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// parseSources reads `suricata-update list-sources`: a "Name: x" line starts
// a source, and the indented "Key: value" lines after it describe it.
func parseSources(text string) []Source {
	var list []Source
	for _, line := range strings.Split(ansi.ReplaceAllString(text, ""), "\n") {
		line = strings.TrimRight(line, "\r")
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		indented := strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t")
		switch {
		case !indented && key == "Name":
			list = append(list, Source{Name: value})
		case indented && len(list) > 0:
			last := &list[len(list)-1]
			switch key {
			case "Vendor":
				last.Vendor = value
			case "Summary":
				last.Summary = value
			case "License":
				last.License = value
			}
		}
	}
	return list
}

// parseEnabled reads `suricata-update list-enabled-sources`. The bullets
// under "Enabled sources:" are the sources in the data directory; bullets
// under "From <file>:" and "Local files/directories:" are other things.
func parseEnabled(text string) []string {
	var names []string
	inEnabled := false
	for _, line := range strings.Split(ansi.ReplaceAllString(text, ""), "\n") {
		line = strings.TrimRight(line, "\r")
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == "Enabled sources:":
			inEnabled = true
		case strings.HasPrefix(trimmed, "- "):
			if inEnabled {
				names = append(names, strings.TrimSpace(strings.TrimPrefix(trimmed, "- ")))
			}
		case trimmed != "":
			inEnabled = false
		}
	}
	return names
}

// mergeSources marks the listed sources that are enabled and appends the
// enabled ones the index does not know.
func mergeSources(index []Source, enabled []string) []Source {
	on := make(map[string]bool, len(enabled))
	for _, n := range enabled {
		on[n] = true
	}
	known := make(map[string]bool, len(index))
	out := make([]Source, 0, len(index)+len(enabled))
	for _, s := range index {
		s.Enabled = on[s.Name]
		known[s.Name] = true
		out = append(out, s)
	}
	for _, n := range enabled {
		if !known[n] {
			known[n] = true
			out = append(out, Source{Name: n, Enabled: true, Custom: true})
		}
	}
	return out
}
