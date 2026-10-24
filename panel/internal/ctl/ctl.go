// Package ctl runs dpistack, the only privileged helper the panel may
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
	"unicode/utf8"
)

// callTimeout bounds one ctl call; `status` asks systemd about every component.
const callTimeout = 15 * time.Second

// maxOutput keeps a runaway helper from filling panel memory.
const maxOutput = 1 << 20

// maxLogOutput is larger: 1000 journal lines can be long.
const maxLogOutput = 4 << 20

// maxLine bounds one streamed log line.
const maxLine = 1 << 20

// writeTimeout bounds config-write: `suricata -T` loads the whole ruleset,
// and --apply may restart a component or run reconfigure.
const writeTimeout = 3 * time.Minute

// maxChecker keeps the checker's own words, which travel in the error.
const maxChecker = 64 << 10

// stopGrace is how long a streamed ctl gets to exit after its stdin is closed.
const stopGrace = 5 * time.Second

// ErrUnavailable means dpistack could not be run or gave unusable output.
var ErrUnavailable = errors.New("dpistack unavailable")

// ExitError means dpistack ran and refused or failed. Code is its exit
// status (tech.md 4.5: 1 failure, 2 bad arguments, 3 not supported in this
// mode, 4 component not installed, 5 argument not allowed) and Message the
// first line it wrote to stderr, in Russian, fit to show to the user.
type ExitError struct {
	Code    int
	Message string
	// Output is what ctl printed to stdout before it failed: for
	// config-write, the words of the checker (suricata -T and the like).
	Output string
}

func (e *ExitError) Error() string {
	if e.Message != "" {
		return fmt.Sprintf("exit code %d: %s", e.Code, e.Message)
	}
	return fmt.Sprintf("exit code %d", e.Code)
}

// Runner calls dpistack, through `sudo -n` when Sudo is set.
type Runner struct {
	Path string
	Sudo bool
	// Prefix runs dpistack on the host from inside a container: the panel in
	// Docker starts it through `nsenter -t 1 -m -u -i -n -p --`, and the
	// caller is named in the environment so that dpistack gives it the verbs
	// and no installer command, as it does for the sudo path.
	Prefix []string
}

// Component is one entry of `dpistack status --json`.
type Component struct {
	ID      string `json:"id"`
	Runtime string `json:"runtime"`
	State   string `json:"state"`
	Enabled bool   `json:"enabled"`
	Version string `json:"version"`
}

// Status is the output of `dpistack status --json`.
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

// ConfigRead returns the current text of a config file.
func (r *Runner) ConfigRead(ctx context.Context, name string) (string, error) {
	out, err := r.runWith(ctx, maxLogOutput, callTimeout, nil, "config-read", name)
	return string(out), err
}

// ConfigWrite hands content to `config-write <name>`: mode "" saves, "--check"
// only checks, "--apply" saves and applies. The output is what ctl printed.
func (r *Runner) ConfigWrite(ctx context.Context, name, mode string, content []byte) (string, error) {
	args := []string{"config-write", name}
	switch mode {
	case "":
	case "--check", "--apply":
		args = append(args, mode)
	default:
		return "", fmt.Errorf("ctl: config-write mode %q is not allowed", mode)
	}
	out, err := r.runWith(ctx, maxOutput, writeTimeout, content, args...)
	return strings.TrimSpace(string(out)), err
}

// ConfigRevert runs `config-revert <name>`.
func (r *Runner) ConfigRevert(ctx context.Context, name string) (string, error) {
	out, err := r.runWith(ctx, maxOutput, callTimeout, nil, "config-revert", name)
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
	switch {
	case len(r.Prefix) > 0:
		name = r.Prefix[0]
		argv = append(append(append([]string{}, r.Prefix[1:]...), "env", "DPISTACK_CALLER=panel", r.Path), args...)
	case r.Sudo:
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
	return r.runWith(ctx, limit, callTimeout, nil, args...)
}

// runWith is run with its own timeout and a stdin.
func (r *Runner) runWith(ctx context.Context, limit int, timeout time.Duration, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := r.command(ctx, args...)
	stdout := limitedBuffer{max: limit}
	var stderr limitedBuffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("%w: no answer in %s", ErrUnavailable, timeout)
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			out := strings.TrimSpace(stdout.String())
			out = cutUTF8(out, maxChecker)
			return nil, &ExitError{Code: exit.ExitCode(), Message: firstLine(stderr.String()), Output: out}
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
// "dpistack: " prefix it puts on its own messages.
func firstLine(stderr string) string {
	msg := strings.TrimSpace(stderr)
	if i := strings.IndexByte(msg, '\n'); i >= 0 {
		msg = msg[:i]
	}
	msg = strings.TrimPrefix(msg, "dpistack: ")
	return cutUTF8(msg, 200)
}

// cutUTF8 shortens s to at most n bytes without cutting a character in
// half: the messages are Russian, two bytes a letter, and half a letter
// reaches the screen as a replacement sign.
func cutUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}
