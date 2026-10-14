// Package ctl runs dpistack-ctl, the only privileged helper the panel may
// call (tech.md 4.5). The panel never runs any other command.
package ctl

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// callTimeout bounds one ctl call; `status` asks systemd about every component.
const callTimeout = 15 * time.Second

// maxOutput keeps a runaway helper from filling panel memory.
const maxOutput = 1 << 20

// maxLogOutput is larger: 1000 journal lines can be long.
const maxLogOutput = 4 << 20

// maxLine bounds one streamed log line.
const maxLine = 1 << 20

// stopGrace is how long a streamed ctl gets to exit after its stdin is closed.
const stopGrace = 5 * time.Second

// ErrUnavailable means dpistack-ctl could not be run or gave unusable output.
var ErrUnavailable = errors.New("dpistack-ctl unavailable")

// ExitError means dpistack-ctl ran and refused or failed. Code is its exit
// status (tech.md 4.5: 1 failure, 2 bad arguments, 3 not supported in this
// mode, 4 component not installed, 5 argument not allowed) and Message the
// first line it wrote to stderr, in Russian, fit to show to the user.
type ExitError struct {
	Code    int
	Message string
}

func (e *ExitError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("exit code %d: %s", e.Code, e.Message)
	}
	return fmt.Sprintf("exit code %d", e.Code)
}

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

// Status runs `status --json`. Any failure counts as ErrUnavailable: the
// panel cannot show a state without it.
func (r *Runner) Status(ctx context.Context) (*Status, error) {
	out, err := r.run(ctx, maxOutput, "status", "--json")
	if err != nil {
		return nil, unavailable(err)
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

// Control runs `start|stop|restart <id>` and returns what ctl printed.
func (r *Runner) Control(ctx context.Context, verb, id string) (string, error) {
	switch verb {
	case "start", "stop", "restart":
	default:
		return "", fmt.Errorf("ctl: verb %q is not allowed", verb)
	}
	out, err := r.run(ctx, maxOutput, verb, id)
	return strings.TrimSpace(string(out)), err
}

// ReloadSuricata runs `reload suricata`.
func (r *Runner) ReloadSuricata(ctx context.Context) (string, error) {
	out, err := r.run(ctx, maxOutput, "reload", "suricata")
	return strings.TrimSpace(string(out)), err
}

// Logs returns the last n journal lines of a component.
func (r *Runner) Logs(ctx context.Context, id string, n int) ([]string, error) {
	out, err := r.run(ctx, maxLogOutput, "logs", id, "-n", strconv.Itoa(n))
	if err != nil {
		return nil, err
	}
	text := strings.TrimRight(string(out), "\n")
	if text == "" {
		return []string{}, nil
	}
	return strings.Split(text, "\n"), nil
}

// Follow streams `logs <id> -n N --follow` line by line into emit until the
// stream ends, emit fails or ctx is cancelled.
//
// The panel is not root, so it cannot signal the sudo process in front of
// ctl: a kill would fail and leave journalctl running. Instead it holds ctl's
// stdin open and closes it to stop the stream (ctl's --until-stdin-closed),
// which works even when the journal is quiet.
func (r *Runner) Follow(ctx context.Context, id string, n int, emit func(line string) error) error {
	cmd := r.command(ctx, "logs", id, "-n", strconv.Itoa(n), "--until-stdin-closed")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	var stderr limitedBuffer
	cmd.Stderr = &stderr
	cmd.Cancel = func() error { return stdin.Close() }
	cmd.WaitDelay = stopGrace
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}

	var emitErr error
	reader := bufio.NewReaderSize(stdout, 64<<10)
	for {
		line, tooLong, rerr := readLine(reader)
		if line != "" || tooLong {
			if emitErr = emit(line); emitErr != nil {
				break
			}
		}
		if rerr != nil {
			break
		}
	}
	// Whatever ended the loop, ask ctl to stop and wait for it.
	stdin.Close()
	_, _ = io.Copy(io.Discard, stdout)
	waitErr := cmd.Wait()

	if emitErr != nil {
		return emitErr
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	var exit *exec.ExitError
	if errors.As(waitErr, &exit) {
		return &ExitError{Code: exit.ExitCode(), Message: firstLine(stderr.String())}
	}
	if waitErr != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, waitErr)
	}
	return nil
}

// readLine returns one line without its newline. A line longer than maxLine
// is cut at maxLine and the rest of it dropped.
func readLine(r *bufio.Reader) (line string, tooLong bool, err error) {
	var buf []byte
	for {
		chunk, isPrefix, rerr := r.ReadLine()
		if len(buf) < maxLine {
			buf = append(buf, chunk...)
		} else {
			tooLong = true
		}
		if rerr != nil {
			return strings.TrimRight(string(buf), "\r"), tooLong, rerr
		}
		if !isPrefix {
			return strings.TrimRight(string(buf), "\r"), tooLong, nil
		}
	}
}

type limitedBuffer struct {
	bytes.Buffer
	over bool
	max  int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	limit := b.max
	if limit == 0 {
		limit = maxOutput
	}
	if b.Len()+len(p) > limit {
		b.over = true
		return len(p), nil
	}
	return b.Buffer.Write(p)
}

func (r *Runner) command(ctx context.Context, args ...string) *exec.Cmd {
	name, argv := r.Path, args
	if r.Sudo {
		name, argv = "sudo", append([]string{"-n", r.Path}, args...)
	}
	cmd := exec.CommandContext(ctx, name, argv...)
	cmd.Env = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C.UTF-8"}
	cmd.WaitDelay = time.Second
	return cmd
}

// run executes one ctl call. A non-zero exit is an *ExitError; failing to
// run ctl at all, or output past limit, is ErrUnavailable.
func (r *Runner) run(ctx context.Context, limit int, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()

	cmd := r.command(ctx, args...)
	stdout := limitedBuffer{max: limit}
	var stderr limitedBuffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return nil, &ExitError{Code: exit.ExitCode(), Message: firstLine(stderr.String())}
		}
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	if stdout.over {
		return nil, fmt.Errorf("%w: output too large", ErrUnavailable)
	}
	return stdout.Bytes(), nil
}

// unavailable turns any run failure into ErrUnavailable with a short reason.
func unavailable(err error) error {
	if errors.Is(err, ErrUnavailable) {
		return err
	}
	return fmt.Errorf("%w: %s", ErrUnavailable, err)
}

// firstLine returns the first line of ctl's stderr, without the
// "dpistack-ctl: " prefix it puts on its own messages.
func firstLine(stderr string) string {
	msg := strings.TrimSpace(stderr)
	if i := strings.IndexByte(msg, '\n'); i >= 0 {
		msg = msg[:i]
	}
	msg = strings.TrimPrefix(msg, "dpistack-ctl: ")
	if len(msg) > 200 {
		msg = msg[:200]
	}
	return msg
}
