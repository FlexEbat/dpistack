package ctl

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// SettingsTimeout bounds `settings set --apply`, which runs reconfigure.
const SettingsTimeout = 3 * time.Minute

// SettingsList runs `settings list --json`: every key of the schema with its
// value, as ctl printed it.
func (r *Runner) SettingsList(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, callTimeout, nil, "settings", "list", "--json")
}

// pairsInput is KEY=VALUE one per line, what ctl reads on stdin: a value may
// hold characters that the argument check of every verb refuses.
func pairsInput(keys []string, values map[string]string) []byte {
	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k + "=" + values[k] + "\n")
	}
	return []byte(b.String())
}

// SettingsCheck runs `settings check` and returns its JSON. A change that
// does not pass is exit 3 with the same JSON in Output, which the caller
// shows; it is an answer, not a failure of the call.
func (r *Runner) SettingsCheck(ctx context.Context, keys []string, values map[string]string) ([]byte, error) {
	return r.runWith(ctx, maxOutput, writeTimeout, pairsInput(keys, values), "settings", "check")
}

// SettingsSet runs `settings set`: mode "" only records the change, "--apply"
// applies a light one, "--apply-heavy" starts the heavy reconfigure as a
// unit. confirmAccess carries the person's explicit consent to a changed
// ACCESS_MODE.
func (r *Runner) SettingsSet(ctx context.Context, mode string, confirmAccess bool, keys []string, values map[string]string) (string, error) {
	args := []string{"settings", "set"}
	switch mode {
	case "":
	case "--apply", "--apply-heavy":
		args = append(args, mode)
	default:
		return "", fmt.Errorf("ctl: settings set mode %q is not allowed", mode)
	}
	if confirmAccess {
		args = append(args, "--confirm-access")
	}
	out, err := r.runWith(ctx, maxOutput, SettingsTimeout, pairsInput(keys, values), args...)
	return strings.TrimSpace(string(out)), err
}

// SettingsSecret runs `settings secret <key>`; the value goes on stdin.
func (r *Runner) SettingsSecret(ctx context.Context, key, value string) (string, error) {
	out, err := r.runWith(ctx, maxOutput, SettingsTimeout, []byte(value+"\n"), "settings", "secret", key)
	return strings.TrimSpace(string(out)), err
}

// SettingsJob runs `settings job`: the state and log of the heavy apply.
func (r *Runner) SettingsJob(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, callTimeout, nil, "settings", "job")
}
