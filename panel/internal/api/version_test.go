package api

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/update"
)

const updateCtlScript = `#!/bin/sh
echo "$*" >> '@LOG@'
[ "$1" = self-update ] || exit 0
case "$2" in
run) echo "update started" ;;
job) echo '{"state":"active","result":"","log":["fetching"]}' ;;
esac
`

func releaseServer(t *testing.T, tag string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"tag_name":"` + tag + `","html_url":"https://github.com/FlexEbat/dpistack/releases/tag/` + tag + `"}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func updateEnv(t *testing.T, running, latestTag string) (*env, *opsCtl) {
	t.Helper()
	c := newOpsCtl(t)
	script := strings.NewReplacer("@LOG@", c.log, "@DIR@", c.dir).Replace(updateCtlScript)
	if err := os.WriteFile(c.runner.Path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	srv := releaseServer(t, latestTag)
	e := setup(t, withOpsCtl(c), func(cfg *Config, _ string) {
		cfg.Version = running
		cfg.Update = &update.Checker{Current: running, URL: srv.URL}
	})
	return e, c
}

func TestVersionShowsRunningAndNewerRelease(t *testing.T) {
	e, _ := updateEnv(t, "0.25.2", "v0.26.0")
	cookies, csrf := e.login()
	w := send(e, "GET", "/api/version", "", cookies, csrf)
	m := jsonMap(t, w.Body.Bytes())
	if w.Code != 200 || m["version"] != "0.25.2" || m["latest"] != "0.26.0" || m["update_available"] != true {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

func TestVersionNeedsSignIn(t *testing.T) {
	e, _ := updateEnv(t, "0.25.2", "v0.26.0")
	if w := send(e, "GET", "/api/version", "", nil, ""); w.Code != 401 {
		t.Fatalf("%d", w.Code)
	}
}

func TestVersionWithoutCheckerStillShowsTheVersion(t *testing.T) {
	e := setup(t, func(cfg *Config, _ string) { cfg.Version = "0.25.2" })
	cookies, csrf := e.login()
	w := send(e, "GET", "/api/version", "", cookies, csrf)
	m := jsonMap(t, w.Body.Bytes())
	if w.Code != 200 || m["version"] != "0.25.2" || m["update_available"] != false {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}

func TestUpdateStartsTheRootVerbOnlyWhenNewer(t *testing.T) {
	e, c := updateEnv(t, "0.25.2", "v0.26.0")
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/update", "", cookies, csrf)
	if w.Code != 202 || !c.called(t, "self-update run") {
		t.Fatalf("%d %s calls=%q", w.Code, w.Body, c.calls(t))
	}
}

func TestUpdateRefusedWhenUpToDate(t *testing.T) {
	e, c := updateEnv(t, "0.25.2", "v0.25.2")
	cookies, csrf := e.login()
	w := send(e, "POST", "/api/update", "", cookies, csrf)
	if w.Code != 409 || c.called(t, "self-update run") {
		t.Fatalf("%d %s calls=%q", w.Code, w.Body, c.calls(t))
	}
}

func TestUpdateNeedsCSRFToken(t *testing.T) {
	e, c := updateEnv(t, "0.25.2", "v0.26.0")
	cookies, _ := e.login()
	if w := send(e, "POST", "/api/update", "", cookies, "wrong"); w.Code != 403 || c.called(t, "self-update run") {
		t.Fatalf("%d", w.Code)
	}
}

func TestUpdateJobPassesThrough(t *testing.T) {
	e, _ := updateEnv(t, "0.25.2", "v0.26.0")
	cookies, csrf := e.login()
	w := send(e, "GET", "/api/update/job", "", cookies, csrf)
	if w.Code != 200 || jsonMap(t, w.Body.Bytes())["state"] != "active" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}
