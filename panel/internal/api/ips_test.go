package api

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// ipsScript stands in for `ips status|test`: it logs its arguments and
// answers with a file.
const ipsScript = `#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/calls.log"
case "$2" in
status) cat "$dir/ips-status.json" ;;
test) [ -f "$dir/REFUSE" ] && { echo "dpistack: ips test: no such pcap" >&2; exit 5; }; cat "$dir/ips-test.json" ;;
esac
`

var ipsFiles = map[string]string{
	"ips-status.json": `{"mode":"ips","method":"nfq","chains":["INPUT"],"backend":"iptables","pending":false,"remaining_sec":0,"drop_rules":{"enabled":2,"disabled":1,"local_enabled":1,"local_disabled":0},"counters":null,"blocked":[],"checks":[{"id":"queue","state":"ok","text":"x"}],"ready":true}`,
	"ips-test.json":   `{"ran":true,"pcap":"bittorrent","simulate_ips":true,"loaded":3,"matched":[{"sid":1000002,"msg":"drop two","would_drop":true}],"would_drop":1,"requested":[]}`,
}

func ipsEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		users := filepath.Join(dir, "users.json")
		if err := os.WriteFile(users, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = users
		files := map[string]string{"ctl": ipsScript}
		for k, v := range ipsFiles {
			files[k] = v
		}
		for name, text := range files {
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

func TestIPSStatusPassesTheVerbJSONThrough(t *testing.T) {
	e := ipsEnv(t)
	w := e.as("vi", "GET", "/api/ips", "")
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != ipsFiles["ips-status.json"] {
		t.Fatalf("status: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ips status --json\n") {
		t.Errorf("the verb was called with: %q", e.calls())
	}
}

func TestIPSStatusThatIsNotJSONIsAServerError(t *testing.T) {
	e := ipsEnv(t)
	if err := os.WriteFile(filepath.Join(e.dir, "ips-status.json"), []byte("text"), 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("vi", "GET", "/api/ips", ""); w.Code != http.StatusInternalServerError {
		t.Errorf("a verb that printed text: %d", w.Code)
	}
}

func TestIPSTestRunsTheVerbWithCheckedArguments(t *testing.T) {
	e := ipsEnv(t)
	w := e.as("an", "POST", "/api/ips/test", `{"sids":[1000002,9000001],"pcap":"bittorrent"}`)
	if w.Code != 200 || strings.TrimSpace(w.Body.String()) != ipsFiles["ips-test.json"] {
		t.Fatalf("test: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ips test --json --sid 1000002,9000001 --pcap bittorrent\n") {
		t.Errorf("arguments: %q", e.calls())
	}
	if w := e.as("an", "POST", "/api/ips/test", ``); w.Code != 200 {
		t.Errorf("an empty body runs the default test: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "ips test --json\n") {
		t.Errorf("the default call: %q", e.calls())
	}
}

func TestIPSTestRefusesBadInputBeforeCtl(t *testing.T) {
	e := ipsEnv(t)
	var many []string
	for i := 0; i < 21; i++ {
		many = append(many, "1")
	}
	for name, body := range map[string]string{
		"text sid":    `{"sids":["abc"]}`,
		"float sid":   `{"sids":[1.5]}`,
		"negative":    `{"sids":[-1]}`,
		"huge":        `{"sids":[12345678901]}`,
		"21 sids":     `{"sids":[` + strings.Join(many, ",") + `]}`,
		"path pcap":   `{"pcap":"../etc/passwd"}`,
		"upper pcap":  `{"pcap":"BitTorrent"}`,
		"not json":    `{`,
		"wrong shape": `{"sids":"1"}`,
	} {
		if w := e.as("an", "POST", "/api/ips/test", body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", name, w.Code, w.Body)
		}
	}
	if strings.Contains(e.calls(), "ips test") {
		t.Errorf("a refused request reached the verb: %q", e.calls())
	}
}

func TestIPSTestExitCodeFiveIsBadRequest(t *testing.T) {
	e := ipsEnv(t)
	if err := os.WriteFile(filepath.Join(e.dir, "REFUSE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if w := e.as("an", "POST", "/api/ips/test", `{"pcap":"nothere"}`); w.Code != http.StatusBadRequest {
		t.Errorf("code 5: %d %s", w.Code, w.Body)
	}
}

func TestIPSPermissions(t *testing.T) {
	e := ipsEnv(t)
	if w := e.as("vi", "GET", "/api/ips", ""); w.Code != 200 {
		t.Errorf("a viewer sees the page: %d", w.Code)
	}
	if w := e.as("vi", "POST", "/api/ips/test", `{}`); w.Code != http.StatusForbidden {
		t.Errorf("a viewer may not run the test: %d", w.Code)
	}
	if w := e.as("cu", "POST", "/api/ips/test", `{}`); w.Code != http.StatusForbidden {
		t.Errorf("a custom user without tests.run: %d", w.Code)
	}
}
