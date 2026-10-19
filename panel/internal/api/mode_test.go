package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// modeCall returns the status code and the decoded body; "mode" in the body
// of a POST answer is an object, so it is read apart.
func modeCall(e *env, method, path, body string, cookies []*http.Cookie, csrf string) (int, map[string]json.RawMessage) {
	w := send(e, method, path, body, cookies, csrf)
	var m map[string]json.RawMessage
	_ = json.Unmarshal(w.Body.Bytes(), &m)
	return w.Code, m
}

func str(m map[string]json.RawMessage, key string) string {
	var s string
	_ = json.Unmarshal(m[key], &s)
	return s
}

func nested(t *testing.T, m map[string]json.RawMessage) (mode string, pending bool, remaining int) {
	t.Helper()
	var st struct {
		Mode         string `json:"mode"`
		Pending      bool   `json:"pending"`
		RemainingSec int    `json:"remaining_sec"`
	}
	if err := json.Unmarshal(m["mode"], &st); err != nil {
		t.Fatalf("mode object: %v (%s)", err, m["mode"])
	}
	return st.Mode, st.Pending, st.RemainingSec
}

// Criterion 6: the switch to ips is refused unless it was confirmed by a
// person, so a bare request cannot cut the network.
func TestModeIPSNeedsAnAcknowledgement(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	code, m := modeCall(e, "POST", "/api/mode", `{"mode":"ips"}`, cookies, csrf)
	if code != http.StatusBadRequest || !strings.Contains(str(m, "error"), "подтвердить") {
		t.Fatalf("without acknowledgement: %d %v", code, m)
	}
	for _, call := range c.calls(t) {
		if strings.HasPrefix(call, "mode ips") {
			t.Errorf("ctl was called anyway: %q", c.calls(t))
		}
	}
}

// Criterion 6: with the confirmation the panel asks ctl for ips and the
// answer carries the countdown the screen shows.
func TestModeIPSReturnsTheCountdown(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	code, m := modeCall(e, "POST", "/api/mode", `{"mode":"ips","acknowledged":true,"confirm_timeout":90}`, cookies, csrf)
	if code != http.StatusOK {
		t.Fatalf("switch: %d %v", code, m)
	}
	mode, pending, remaining := nested(t, m)
	if mode != "ips" || !pending || remaining != 90 {
		t.Errorf("state after the switch: %s %v %d", mode, pending, remaining)
	}
	if !c.called(t, "mode ips --confirm-timeout 90") {
		t.Errorf("ctl calls: %q", c.calls(t))
	}

	code, m = modeCall(e, "GET", "/api/mode", "", cookies, csrf)
	var remainingSec int
	_ = json.Unmarshal(m["remaining_sec"], &remainingSec)
	if code != http.StatusOK || str(m, "mode") != "ips" || remainingSec != 90 {
		t.Errorf("GET /api/mode: %d %v", code, m)
	}
}

func TestModeConfirmEndsTheCountdown(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	modeCall(e, "POST", "/api/mode", `{"mode":"ips","acknowledged":true}`, cookies, csrf)

	code, m := modeCall(e, "POST", "/api/mode/confirm", ``, cookies, csrf)
	if code != http.StatusOK {
		t.Fatalf("confirm: %d %v", code, m)
	}
	mode, pending, _ := nested(t, m)
	if mode != "ips" || pending {
		t.Errorf("after the confirmation: %s pending=%v", mode, pending)
	}
	// nothing is left to confirm: ctl says 3, the panel says conflict
	code, m = modeCall(e, "POST", "/api/mode/confirm", ``, cookies, csrf)
	if code != http.StatusConflict || !strings.Contains(str(m, "error"), "нечего подтверждать") {
		t.Errorf("second confirmation: %d %v", code, m)
	}
}

func TestModeIDSNeedsNoAcknowledgement(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	modeCall(e, "POST", "/api/mode", `{"mode":"ips","acknowledged":true}`, cookies, csrf)

	code, m := modeCall(e, "POST", "/api/mode", `{"mode":"ids"}`, cookies, csrf)
	mode, pending, _ := nested(t, m)
	if code != http.StatusOK || mode != "ids" || pending {
		t.Errorf("back to ids: %d %s %v", code, mode, pending)
	}
}

func TestModeRejectsBadRequests(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()
	for _, body := range []string{
		`{"mode":"bogus"}`,
		`{"mode":"ips","acknowledged":true,"confirm_timeout":5}`,
		`{"mode":"ips","acknowledged":true,"confirm_timeout":99999}`,
		`not json`,
	} {
		if code, _ := modeCall(e, "POST", "/api/mode", body, cookies, csrf); code != http.StatusBadRequest {
			t.Errorf("%s: %d", body, code)
		}
	}
	if len(c.calls(t)) != 0 {
		t.Errorf("ctl was called for bad requests: %q", c.calls(t))
	}
}

// ctl refuses ips for want of iptables (exit 3): a conflict with the state
// of the host, shown to the person as it is.
func TestModeCtlRefusalIsAConflictWithItsMessage(t *testing.T) {
	c := newOpsCtl(t)
	c.write(t, "FAIL", "1")
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	code, m := modeCall(e, "POST", "/api/mode", `{"mode":"ips","acknowledged":true}`, cookies, csrf)
	if code != http.StatusConflict || !strings.Contains(str(m, "error"), "iptables") {
		t.Errorf("refusal: %d %v", code, m)
	}
}

func TestSecondModeSwitchIs409(t *testing.T) {
	c := newOpsCtl(t)
	c.write(t, "HOLD", "1")
	e := setup(t, withOpsCtl(c))
	cookies, csrf := e.login()

	done := make(chan int, 1)
	go func() {
		code, _ := modeCall(e, "POST", "/api/mode", `{"mode":"ips","acknowledged":true}`, cookies, csrf)
		done <- code
	}()
	// wait until the first request is inside ctl
	deadline := time.Now().Add(5 * time.Second)
	for !c.called(t, "mode ips") && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if code, _ := modeCall(e, "POST", "/api/mode", `{"mode":"ids"}`, cookies, csrf); code != http.StatusConflict {
		t.Errorf("second switch: %d", code)
	}
	if err := removeFile(c, "HOLD"); err != nil {
		t.Fatal(err)
	}
	if code := <-done; code != http.StatusOK {
		t.Errorf("first switch: %d", code)
	}
}

func TestModeNeedsALogin(t *testing.T) {
	c := newOpsCtl(t)
	e := setup(t, withOpsCtl(c))
	for _, req := range [][2]string{{"GET", "/api/mode"}, {"POST", "/api/mode"}, {"POST", "/api/mode/confirm"}} {
		if w := send(e, req[0], req[1], `{"mode":"ids"}`, nil, ""); w.Code != http.StatusUnauthorized && w.Code != http.StatusForbidden {
			t.Errorf("%s %s without a session: %d", req[0], req[1], w.Code)
		}
	}
}

func removeFile(c *opsCtl, name string) error { return os.Remove(filepath.Join(c.dir, name)) }
