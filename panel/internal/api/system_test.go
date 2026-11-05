package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
	"github.com/FlexEbat/dpistack/panel/internal/system"
)

func systemEnv(t *testing.T, ifaces string) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		path := filepath.Join(dir, "users.json")
		if err := os.WriteFile(path, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = path
		net := filepath.Join(dir, "sys", "class", "net")
		for _, n := range []string{"eth0", "eth1"} {
			if err := os.MkdirAll(filepath.Join(net, n), 0o755); err != nil {
				t.Fatal(err)
			}
			_ = os.WriteFile(filepath.Join(net, n, "operstate"), []byte("up\n"), 0o644)
		}
		c.System = &system.Reader{Proc: filepath.Join(dir, "proc"), Sys: filepath.Join(dir, "sys"), Run: dir}
		script := filepath.Join(dir, "ctl")
		body := "#!/bin/sh\necho \"$*\" >> \"$(dirname \"$0\")/calls.log\"\n"
		if ifaces == "fail" {
			body += "exit 1\n"
		} else {
			body += "printf '" + ifaces + "'\n"
		}
		if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: script}
	})
}

func TestSystemMarksTheCapturingInterfaces(t *testing.T) {
	e := systemEnv(t, "eth1\\n")
	w := e.as("vi", "GET", "/api/system", "")
	if w.Code != 200 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	var got system.Info
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Interfaces) != 2 || got.Interfaces[0].Capture == nil || *got.Interfaces[0].Capture || !*got.Interfaces[1].Capture {
		t.Errorf("capture flags: %+v", got.Interfaces)
	}
	if !strings.Contains(e.calls(), "iface list") {
		t.Errorf("calls: %q", e.calls())
	}
}

func TestSystemLeavesTheFlagOutWhenCtlFails(t *testing.T) {
	e := systemEnv(t, "fail")
	w := e.as("vi", "GET", "/api/system", "")
	if w.Code != 200 || strings.Contains(w.Body.String(), `"capture"`) {
		t.Errorf("%d %s", w.Code, w.Body)
	}
}

func TestSystemIsOffWithoutAReader(t *testing.T) {
	e := setup(t, func(c *Config, dir string) {
		path := filepath.Join(dir, "users.json")
		_ = os.WriteFile(path, []byte(usersJSON(false)), 0o640)
		c.UsersFile = path
	})
	if w := e.as("vi", "GET", "/api/system", ""); w.Code != http.StatusNotFound {
		t.Errorf("%d", w.Code)
	}
}
