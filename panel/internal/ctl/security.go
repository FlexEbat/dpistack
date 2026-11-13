package ctl

import (
	"context"
	"strconv"
)

// The security page (tech.md 18.45). Each method runs one verb and returns
// what it printed on stdout, unchanged. The caller has checked the values
// against the same patterns as the verb.

// TokensCreate runs `tokens create --json`; the answer holds the secret, which
// is shown once and kept nowhere.
func (r *Runner) TokensCreate(ctx context.Context, user, name, scope string, days int) ([]byte, error) {
	return r.runWith(ctx, maxOutput, writeTimeout, nil, "tokens", "create", "--json",
		"--user", user, "--name", name, "--scope", scope, "--days", strconv.Itoa(days))
}

// TokensRevoke runs `tokens revoke <id> --user <owner>`.
func (r *Runner) TokensRevoke(ctx context.Context, id, owner string) error {
	_, err := r.runWith(ctx, maxOutput, callTimeout, nil, "tokens", "revoke", id, "--user", owner)
	return err
}

// SecurityCheck runs `security check --json`.
func (r *Runner) SecurityCheck(ctx context.Context) ([]byte, error) {
	return r.runWith(ctx, maxOutput, rulesTimeout, nil, "security", "check", "--json")
}
