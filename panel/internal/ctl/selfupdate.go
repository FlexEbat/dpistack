package ctl

import "context"

// SelfUpdateStart runs `self-update run`: root starts the update as its own
// transient unit and returns at once. The verb takes no argument: it asks the
// release server itself and installs only a tag newer than what runs.
func (r *Runner) SelfUpdateStart(ctx context.Context) (string, error) {
	out, err := r.runWith(ctx, maxOutput, callTimeout, nil, "self-update", "run")
	return string(out), err
}

// SelfUpdateJob runs `self-update job`: the state and log of that unit.
func (r *Runner) SelfUpdateJob(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, callTimeout, nil, "self-update", "job")
}
