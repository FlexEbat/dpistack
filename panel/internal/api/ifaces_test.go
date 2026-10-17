package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type ifaceAnswer struct {
	Ok     bool
	Output string
	Ifaces []string
	Error  string
}

func ifaceCall(e *env, method, path, body string, cookies []*http.Cookie, csrf string) (int, ifaceAnswer) {
	w := send(e, method, path, body, cookies, csrf)
	var a ifaceAnswer
	_ = json.Unmarshal(w.Body.Bytes(), &a)
	return w.Code, a
}

func (c *opsCtl) ifaces(t *testing.T) string {
	data, err := os.ReadFile(filepath.Join(c.dir, "ifaces"))
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(strings.Fields(string(data)), ",")
}

// Criterion 4: add and remove go through `ctl iface`, and the answer carries
// the new list so the screen can show the status.
func TestIfaceAddAndRemoveGoThroughCtl(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	if code, a := ifaceCall(e, "GET", "/api/iface", "", cookies, csrf); code != 200 || strings.Join(a.Ifaces, ",") != "enp2s0" {
		t.Fatalf("list: %d %+v", code, a)
	}

	code, a := ifaceCall(e, "POST", "/api/iface/add", `{"name":"eth1"}`, cookies, csrf)
	if code != 200 || !a.Ok || strings.Join(a.Ifaces, ",") != "enp2s0,eth1" || !strings.Contains(a.Output, "added") {
		t.Fatalf("add: %d %+v", code, a)
	}
	if !c.called(t, "iface add eth1") || c.ifaces(t) != "enp2s0,eth1" {
		t.Errorf("ctl calls %q, list %q", c.calls(t), c.ifaces(t))
	}
	if _, a := ifaceCall(e, "GET", "/api/iface", "", cookies, csrf); strings.Join(a.Ifaces, ",") != "enp2s0,eth1" {
		t.Errorf("the list after add: %v", a.Ifaces)
	}

	code, a = ifaceCall(e, "POST", "/api/iface/remove", `{"name":"enp2s0"}`, cookies, csrf)
	if code != 200 || strings.Join(a.Ifaces, ",") != "eth1" {
		t.Fatalf("remove: %d %+v", code, a)
	}
	if !c.called(t, "iface remove enp2s0") {
		t.Errorf("ctl calls %q", c.calls(t))
	}

	// Adding what is already there is not an error.
	if code, a := ifaceCall(e, "POST", "/api/iface/add", `{"name":"eth1"}`, cookies, csrf); code != 200 || !strings.Contains(a.Output, "уже в списке") {
		t.Errorf("add twice: %d %+v", code, a)
	}
}

// What ctl refuses, the screen reads as a sentence: an interface the system
// does not have (400), the last interface (409), a failed reconfigure (500,
// the list as it was).
func TestIfaceRefusalsAreSentences(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	code, a := ifaceCall(e, "POST", "/api/iface/add", `{"name":"eth9"}`, cookies, csrf)
	if code != http.StatusBadRequest || !strings.Contains(a.Error, "интерфейса нет в системе") {
		t.Errorf("no such interface: %d %+v", code, a)
	}
	code, a = ifaceCall(e, "POST", "/api/iface/remove", `{"name":"enp2s0"}`, cookies, csrf)
	if code != http.StatusConflict || !strings.Contains(a.Error, "последний интерфейс") {
		t.Errorf("last interface: %d %+v", code, a)
	}
	code, a = ifaceCall(e, "POST", "/api/iface/remove", `{"name":"br0"}`, cookies, csrf)
	if code != http.StatusBadRequest || !strings.Contains(a.Error, "нет в IFACES") {
		t.Errorf("not in the list: %d %+v", code, a)
	}

	c.write(t, "FAIL", "")
	code, a = ifaceCall(e, "POST", "/api/iface/add", `{"name":"eth1"}`, cookies, csrf)
	if code != http.StatusInternalServerError || !strings.Contains(a.Error, "dpistack.conf возвращён") {
		t.Errorf("failed reconfigure: %d %+v", code, a)
	}
	if c.ifaces(t) != "enp2s0" {
		t.Errorf("the list changed in spite of the failure: %q", c.ifaces(t))
	}
}

func TestIfaceValuesAreCheckedBeforeCtl(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	for _, body := range []string{`{"name":""}`, `{"name":"a b"}`, `{"name":"eth0;reboot"}`, `{"name":"` + strings.Repeat("a", 16) + `"}`, `{"name":"../x"}`, `{}`, `not json`} {
		if code, _ := ifaceCall(e, "POST", "/api/iface/add", body, cookies, csrf); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", body, code)
		}
	}
	if code, _ := ifaceCall(e, "POST", "/api/iface/purge", `{"name":"eth1"}`, cookies, csrf); code != http.StatusNotFound {
		t.Errorf("an unknown action: %d, want 404", code)
	}
	if n := len(c.calls(t)); n != 0 {
		t.Fatalf("ctl was called for refused values: %q", c.calls(t))
	}
}

// One change at a time: reconfigure restarts Suricata, and two at once would
// race on dpistack.conf.
func TestSecondIfaceChangeIs409(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	c.write(t, "HOLD", "")
	var wg sync.WaitGroup
	wg.Add(1)
	var first int
	go func() {
		defer wg.Done()
		first, _ = ifaceCall(e, "POST", "/api/iface/add", `{"name":"eth1"}`, cookies, csrf)
	}()
	deadline := time.Now().Add(5 * time.Second)
	for !c.called(t, "iface add eth1") {
		if time.Now().After(deadline) {
			t.Fatal("the first change never started")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if code, _ := ifaceCall(e, "POST", "/api/iface/add", `{"name":"br0"}`, cookies, csrf); code != http.StatusConflict {
		t.Errorf("second change: %d, want 409", code)
	}
	if err := os.Remove(filepath.Join(c.dir, "HOLD")); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	if first != 200 || c.ifaces(t) != "enp2s0,eth1" {
		t.Errorf("first change: %d, list %q", first, c.ifaces(t))
	}
}
