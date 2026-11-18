package ctl

import (
	"context"
	"regexp"
	"time"
)

// versionArg is the only shape of version the verb accepts.
var versionArg = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

// planTimeout is longer than callTimeout: the plan downloads the release.
const planTimeout = 120 * time.Second

// SelfUpdateStart runs `self-update run`: root starts the update as its own
// transient unit and returns at once. The verb takes no argument: it asks the
// release server itself and installs only a tag newer than what runs.
// panelVersion is the version the panel runs; with it root can tell an update
// that never reached the panel from a release that does not exist.
func (r *Runner) SelfUpdateStart(ctx context.Context, panelVersion string) (string, error) {
	args := []string{"self-update", "run"}
	if versionArg.MatchString(panelVersion) {
		args = append(args, "--panel-version", panelVersion)
	}
	out, err := r.runWith(ctx, maxOutput, callTimeout, nil, args...)
	return string(out), err
}

// SelfUpdateJob runs `self-update job`: the state and log of that unit.
func (r *Runner) SelfUpdateJob(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, callTimeout, nil, "self-update", "job")
}

// SelfUpdatePlan runs `self-update plan`: what the newest release will do on
// this host (its migrations and the builds it repeats), as text. Nothing is
// installed.
func (r *Runner) SelfUpdatePlan(ctx context.Context) (string, error) {
	out, err := r.runWith(ctx, maxOutput, planTimeout, nil, "self-update", "plan")
	return string(out), err
}
