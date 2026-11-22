package api

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// hostScript stands in for `dpistack ips block|allow` and for the two rule
// verbs: it logs its arguments and fails the way the real verbs do (5 a
// refused value, 3 a file that does not pass suricata -T).
const hostScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
case "$1" in
rules-sid|rules-group) echo "ok $2 $3"; exit 0 ;;
ips) ;;
*) exit 2 ;;
esac
case "$3" in
list) cat "$dir/list.json" ;;
add)
  [ "$4" = "127.0.0.1" ] && { echo "dpistack: ips block add: 127.0.0.1: a loopback or unspecified address is never blocked" >&2; exit 5; }
  [ -f "$dir/CHECK_FAIL" ] && { echo "ERROR: invalid rule"; echo "dpistack: ips: local.rules does not pass suricata -T, file unchanged" >&2; exit 3; }
  echo "$2: $4 (sid 9100000, expires never)" ;;
remove)
  [ "$4" = "203.0.113.99" ] && { echo "dpistack: ips $2 remove: no such entry: $4" >&2; exit 5; }
  echo "removed from the $2 list: $4" ;;
esac
`

const hostList = `[{"address":"198.51.100.7","sid":9100000,"added":"2026-11-22","expires":"never","by":"admin","note":"scanner"}]`

func hostEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		for name, text := range map[string]string{"ctl": hostScript, "list.json": hostList} {
			mode := os.FileMode(0o644)
			if name == "ctl" {
				mode = 0o755
			}
			if err := os.WriteFile(filepath.Join(dir, name), []byte(text), mode); err != nil {
				t.Fatal(err)
			}
		}
		c.Ctl = &ctl.Runner{Path: filepath.Join(dir, "ctl")}
	})
}

func TestHostListReadsTheVerb(t *testing.T) {
	e := hostEnv(t)
	w := e.as("vi", "GET", "/api/ips/block", "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"address":"198.51.100.7"`) || !strings.Contains(w.Body.String(), `"kind":"block"`) {
		t.Fatalf("a viewer reads the list: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ips block list --json\n") {
		t.Errorf("the list comes from the verb: %q", e.calls())
	}
	if w := e.as("vi", "GET", "/api/ips/nonsense", ""); w.Code != 404 {
		t.Errorf("an unknown list is 404: %d", w.Code)
	}
}

// The user comes from the session and not from the body; no days means no
// expiry; a temporary block carries its days.
func TestHostAddRunsTheVerb(t *testing.T) {
	e := hostEnv(t)
	for _, c := range []struct{ name, path, body, want string }{
		{"a block that never expires", "/api/ips/block", `{"address":"198.51.100.7","note":"scanner","by":"mallory"}`,
			"ips block add 198.51.100.7 --note scanner --by op --never"},
		{"a temporary block", "/api/ips/block", `{"address":"203.0.113.0/24","days":7}`,
			"ips block add 203.0.113.0/24 --days 7 --by op"},
		{"an allow", "/api/ips/allow", `{"address":"192.0.2.5"}`,
			"ips allow add 192.0.2.5 --by op --never"},
	} {
		w := e.as("op", "POST", c.path, c.body)
		if w.Code != 200 || !strings.Contains(w.Body.String(), `"ok":true`) {
			t.Fatalf("%s: %d %s", c.name, w.Code, w.Body)
		}
		if !strings.Contains(e.calls(), c.want+"\n") {
			t.Errorf("%s: the verb got\n%s\nwant a line %q", c.name, e.calls(), c.want)
		}
	}
}

func TestHostAddRefusals(t *testing.T) {
	e := hostEnv(t)
	for _, c := range []struct {
		name, role, body string
		want             int
	}{
		{"a viewer cannot block", "vi", `{"address":"198.51.100.7"}`, 403},
		{"not an address", "op", `{"address":"a b;c"}`, 400},
		{"a bad note", "op", `{"address":"198.51.100.7","note":"bad;note"}`, 400},
		{"negative days", "op", `{"address":"198.51.100.7","days":-1}`, 400},
		{"the verb refuses loopback", "op", `{"address":"127.0.0.1"}`, 400},
	} {
		before := e.calls()
		w := e.as(c.role, "POST", "/api/ips/block", c.body)
		if w.Code != c.want {
			t.Errorf("%s: %d %s, want %d", c.name, w.Code, w.Body, c.want)
		}
		if c.want != 400 || c.name == "the verb refuses loopback" {
			continue
		}
		if e.calls() != before {
			t.Errorf("%s: a value the screen refuses must not reach the verb", c.name)
		}
	}
	if w := e.as("op", "POST", "/api/ips/block", `{"address":"198.51.100.7"}`); w.Code != 200 {
		t.Fatalf("control: %d", w.Code)
	}
	if err := os.WriteFile(filepath.Join(e.dir, "CHECK_FAIL"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	w := e.as("op", "POST", "/api/ips/block", `{"address":"198.51.100.8"}`)
	if w.Code != 422 || !strings.Contains(w.Body.String(), "nothing was changed") {
		t.Errorf("a file that does not pass suricata -T is 422: %d %s", w.Code, w.Body)
	}
}

func TestHostRemove(t *testing.T) {
	e := hostEnv(t)
	w := e.as("op", "POST", "/api/ips/block/remove", `{"what":"198.51.100.7"}`)
	if w.Code != 200 || !strings.Contains(e.calls(), "ips block remove 198.51.100.7\n") {
		t.Fatalf("remove by address: %d %s %q", w.Code, w.Body, e.calls())
	}
	w = e.as("op", "POST", "/api/ips/allow/remove", `{"what":"9100001"}`)
	if w.Code != 200 || !strings.Contains(e.calls(), "ips allow remove 9100001\n") {
		t.Fatalf("remove by sid: %d %s", w.Code, w.Body)
	}
	if w := e.as("op", "POST", "/api/ips/block/remove", `{"what":"203.0.113.99"}`); w.Code != 400 {
		t.Errorf("an entry that is not there is 400: %d", w.Code)
	}
	if w := e.as("op", "POST", "/api/ips/block/remove", `{"what":"x y"}`); w.Code != 400 {
		t.Errorf("a bad value is 400: %d", w.Code)
	}
	if w := e.as("vi", "POST", "/api/ips/block/remove", `{"what":"198.51.100.7"}`); w.Code != 403 {
		t.Errorf("a viewer cannot remove: %d", w.Code)
	}
}

func TestRulesDropAndAlert(t *testing.T) {
	e := hostEnv(t)
	for _, c := range []struct{ path, want string }{
		{"/api/rules/sid/2100498/drop", "rules-sid drop 2100498"},
		{"/api/rules/sid/2100498/alert", "rules-sid alert 2100498"},
		{"/api/rules/groups/emerging-p2p/drop", "rules-group drop emerging-p2p"},
		{"/api/rules/groups/emerging-p2p/alert", "rules-group alert emerging-p2p"},
	} {
		w := e.as("op", "POST", c.path, "")
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", c.path, w.Code, w.Body)
		}
		if !strings.Contains(e.calls(), c.want+"\n") {
			t.Errorf("%s: got %q", c.path, e.calls())
		}
	}
	if w := e.as("op", "POST", "/api/rules/sid/2100498/reject", ""); w.Code != 404 {
		t.Errorf("an unknown action is 404: %d", w.Code)
	}
}
