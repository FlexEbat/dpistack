package api

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// pcapScript stands in for `dpistack pcap analyze FILE --json`: it keeps a
// copy of the file it was given and the path, and answers like the verb.
const pcapScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
[ "$1" = pcap ] && [ "$2" = analyze ] || exit 2
f="$3"
[ -r "$f" ] || { echo "dpistack: pcap analyze: no such file: $f" >&2; exit 5; }
cp "$f" "$dir/uploaded"
stat -c %a "$f" > "$dir/mode"
echo "$f" > "$dir/path"
[ "$(head -c 4 "$f")" = "JUNK" ] && { echo "dpistack: pcap analyze: not a pcap or pcapng file" >&2; exit 5; }
echo '{"ran":true,"file":"x.pcap","bytes":8,"flows":1,"packets":2,"alerts":[],"protocols":[{"app_proto":"tls","flows":1,"bytes":10}]}'
`

func pcapEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		if err := os.WriteFile(filepath.Join(dir, "ctl"), []byte(pcapScript), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: filepath.Join(dir, "ctl")}
	})
}

func (e *env) upload(role, contentType, body string) (int, string) {
	cookies, csrf := e.loginAs(role)
	w := e.do(req{method: "POST", path: "/api/pcap/analyze", body: body, cookies: cookies,
		headers: map[string]string{"X-CSRF-Token": csrf, "Content-Type": contentType}})
	return w.Code, w.Body.String()
}

func TestPcapAnalyzeRunsTheVerbOnTheUpload(t *testing.T) {
	e := pcapEnv(t)
	code, body := e.upload("op", "application/octet-stream", "\xd4\xc3\xb2\xa1 a capture")
	if code != 200 || !strings.Contains(body, `"app_proto":"tls"`) {
		t.Fatalf("an operator analyzes a capture: %d %s", code, body)
	}
	got, _ := os.ReadFile(filepath.Join(e.dir, "uploaded"))
	if string(got) != "\xd4\xc3\xb2\xa1 a capture" {
		t.Errorf("the verb got the bytes as sent: %q", got)
	}
	if mode, _ := os.ReadFile(filepath.Join(e.dir, "mode")); strings.TrimSpace(string(mode)) != "600" {
		t.Errorf("the temporary file is private: mode %q", mode)
	}
	path, _ := os.ReadFile(filepath.Join(e.dir, "path"))
	if _, err := os.Stat(strings.TrimSpace(string(path))); !os.IsNotExist(err) {
		t.Errorf("the upload is deleted after the run: %v", err)
	}
	if !strings.Contains(e.calls(), "pcap analyze ") || !strings.Contains(e.calls(), " --json\n") {
		t.Errorf("the verb is `pcap analyze FILE --json`: %q", e.calls())
	}
}

func TestPcapAnalyzeRefusals(t *testing.T) {
	e := pcapEnv(t)
	if code, _ := e.upload("vi", "application/octet-stream", "x"); code != 403 {
		t.Errorf("a viewer cannot analyze: %d", code)
	}
	if code, _ := e.upload("op", "application/json", "{}"); code != 415 {
		t.Errorf("a JSON body is 415: %d", code)
	}
	if code, body := e.upload("op", "application/octet-stream", ""); code != 400 || !strings.Contains(body, "empty") {
		t.Errorf("an empty upload is 400: %d %s", code, body)
	}
	code, body := e.upload("op", "application/octet-stream", "JUNK not a capture")
	if code != 400 || !strings.Contains(body, "not a pcap or pcapng file") {
		t.Errorf("the verb's refusal (exit 5) is 400 with its sentence: %d %s", code, body)
	}
	path, _ := os.ReadFile(filepath.Join(e.dir, "path"))
	if _, err := os.Stat(strings.TrimSpace(string(path))); !os.IsNotExist(err) {
		t.Errorf("a refused upload is deleted too: %v", err)
	}
}
