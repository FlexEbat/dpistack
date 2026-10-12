// Package ctl runs dpistack-ctl, the only privileged helper the panel may
// call (tech.md 4.5). The panel never runs any other command.
package ctl

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// callTimeout bounds one ctl call; `status` asks systemd about every component.
const callTimeout = 15 * time.Second

// maxOutput keeps a runaway helper from filling panel memory.
const maxOutput = 1 << 20

// ErrUnavailable means dpistack-ctl could not be run or gave unusable output.
var ErrUnavailable = errors.New("dpistack-ctl unavailable")

// Runner calls dpistack-ctl, through `sudo -n` when Sudo is set.
type Runner struct {
	Path string
	Sudo bool
}

// Component is one entry of `dpistack-ctl status --json`.
type Component struct {
	ID      string `json:"id"`
	Runtime string `json:"runtime"`
	State   string `json:"state"`
	Enabled bool   `json:"enabled"`
	Version string `json:"version"`
}

// Status is the output of `dpistack-ctl status --json`.
type Status struct {
	Components []Component `json:"components"`
	NDPIPlugin string      `json:"ndpi_plugin"`
}

// Status runs `status --json`.
func (r *Runner) Status(ctx context.Context) (*Status, error) {
	out, err := r.run(ctx, "status", "--json")
	if err != nil {
		return nil, err
	}
	var st Status
	if err := json.Unmarshal(out, &st); err != nil {
		return nil, fmt.Errorf("%w: invalid status output: %v", ErrUnavailable, err)
	}
	if st.Components == nil {
		st.Components = []Component{}
	}
	return &st, nil
}

type limitedBuffer struct {
	bytes.Buffer
	over bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxOutput {
		b.over = true
		return len(p), nil
	}
	return b.Buffer.Write(p)
}

func (r *Runner) run(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()

	name, argv := r.Path, args
	if r.Sudo {
		name, argv = "sudo", append([]string{"-n", r.Path}, args...)
	}
	cmd := exec.CommandContext(ctx, name, argv...)
	cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C.UTF-8"}
	cmd.WaitDelay = time.Second
	var stdout, stderr limitedBuffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", ErrUnavailable, describe(err, stderr.String()))
	}
	if stdout.over {
		return nil, fmt.Errorf("%w: output too large", ErrUnavailable)
	}
	return stdout.Bytes(), nil
}

// describe turns a failed run into one short line for the API error text.
func describe(err error, stderr string) string {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		msg := strings.TrimSpace(stderr)
		if i := strings.IndexByte(msg, '\n'); i >= 0 {
			msg = msg[:i]
		}
		if len(msg) > 200 {
			msg = msg[:200]
		}
		if msg != "" {
			return fmt.Sprintf("exit code %d: %s", exit.ExitCode(), msg)
		}
		return fmt.Sprintf("exit code %d", exit.ExitCode())
	}
	return err.Error()
}
