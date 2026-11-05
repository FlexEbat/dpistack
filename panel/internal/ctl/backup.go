package ctl

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

// BackupInfo is one entry of `backup list --json`.
type BackupInfo struct {
	Name    string `json:"name"`
	Created string `json:"created,omitempty"`
	Program string `json:"program,omitempty"`
	Files   int    `json:"files"`
	Size    int64  `json:"size"`
}

var backupName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*\.tar\.gz$`)

// ValidBackupName reports whether name is the bare file name of an archive:
// no directory, no "..". It is the rule dpistack applies to the panel too.
func ValidBackupName(name string) bool {
	return len(name) <= 100 && backupName.MatchString(name) && !strings.Contains(name, "..")
}

// BackupList runs `backup list --json`, the newest archive first.
func (r *Runner) BackupList(ctx context.Context) ([]BackupInfo, error) {
	out, err := r.runWith(ctx, maxOutput, callTimeout, nil, "backup", "list", "--json")
	if err != nil {
		return nil, err
	}
	list := []BackupInfo{}
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, fmt.Errorf("%w: backup list: %v", ErrUnavailable, err)
	}
	return list, nil
}

// BackupCreate runs `backup create` and returns the file name of the new
// archive and what ctl printed.
func (r *Runner) BackupCreate(ctx context.Context) (name, output string, err error) {
	out, err := r.runWith(ctx, maxOutput, writeTimeout, nil, "backup", "create")
	output = strings.TrimSpace(string(out))
	if err != nil {
		return "", output, err
	}
	first, _, _ := strings.Cut(output, "\n")
	if i := strings.LastIndex(first, "/"); i >= 0 {
		first = first[i+1:]
	}
	if !ValidBackupName(first) {
		return "", output, fmt.Errorf("%w: backup create: no archive name in %q", ErrUnavailable, output)
	}
	return first, output, nil
}

// BackupVerify runs `backup verify <name>`.
func (r *Runner) BackupVerify(ctx context.Context, name string) (string, error) {
	if !ValidBackupName(name) {
		return "", fmt.Errorf("ctl: backup name %q is not allowed", name)
	}
	out, err := r.runWith(ctx, maxOutput, writeTimeout, nil, "backup", "verify", name)
	return strings.TrimSpace(string(out)), err
}

// BackupRestore runs `backup restore <name> [--dry-run]`. A failed check
// makes ctl exit 3 and print the reason to stdout, which the *ExitError keeps.
func (r *Runner) BackupRestore(ctx context.Context, name string, dryRun bool) (string, error) {
	if !ValidBackupName(name) {
		return "", fmt.Errorf("ctl: backup name %q is not allowed", name)
	}
	args := []string{"backup", "restore", name}
	if dryRun {
		args = append(args, "--dry-run")
	}
	out, err := r.runWith(ctx, maxOutput, writeTimeout, nil, args...)
	return strings.TrimSpace(string(out)), err
}
