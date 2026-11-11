package ctl

import (
	"context"
)

// Settings profiles (tech.md 18.44). Each method runs one `settings profile`
// verb and returns the JSON it printed, unchanged. The caller has checked the
// name against the same pattern as the verb.

// SettingsProfileList runs `settings profile list --json`.
func (r *Runner) SettingsProfileList(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, callTimeout, nil, "settings", "profile", "list", "--json")
}

// SettingsProfileShow runs `settings profile show <name> --json`.
func (r *Runner) SettingsProfileShow(ctx context.Context, name string) ([]byte, error) {
	return r.runWith(ctx, maxOutput, callTimeout, nil, "settings", "profile", "show", name, "--json")
}

// SettingsProfileSave runs `settings profile save <name> --by <user>`; the
// pairs go on stdin, because a value may hold characters that the argument
// check of every verb refuses. The verb checks them as `settings check` does.
func (r *Runner) SettingsProfileSave(ctx context.Context, name, by string, keys []string, values map[string]string) error {
	_, err := r.runWith(ctx, maxOutput, writeTimeout, pairsInput(keys, values), "settings", "profile", "save", name, "--by", by)
	return err
}

// SettingsProfileDelete runs `settings profile delete <name> --by <user>`.
func (r *Runner) SettingsProfileDelete(ctx context.Context, name, by string) error {
	_, err := r.runWith(ctx, maxOutput, callTimeout, nil, "settings", "profile", "delete", name, "--by", by)
	return err
}
