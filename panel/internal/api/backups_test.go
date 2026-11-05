package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FlexEbat/dpistack/panel/internal/audit"
	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// backupCtlScript stands in for `dpistack backup ...`. Files next to it
// steer it: BAD makes verify and restore fail the check (exit 3, the reason on
// stdout), GONE makes them answer "no such archive" (exit 4).
const backupCtlScript = `#!/bin/sh
dir="$(dirname "$0")"
echo "$*" >> "$dir/calls.log"
[ "$1" = backup ] || exit 2
case "$2" in
list) printf '[{"name":"dpistack-backup-20261104T100000Z.tar.gz","created":"2026-11-04T10:00:00Z","program":"0.33.0","files":6,"size":2048}]\n' ;;
create) echo "/var/lib/dpistack/archives/dpistack-backup-20261104T101500Z.tar.gz"; echo "backup created: 6 files" ;;
verify|restore)
  [ -f "$dir/GONE" ] && { echo "dpistack: backup: no such archive: $3" >&2; exit 4; }
  [ -f "$dir/BAD" ] && { echo "suricata -T failed on the restored configuration"; echo "dpistack: backup $2: the restored configuration does not pass its checks, nothing changed" >&2; exit 3; }
  if [ "$2" = verify ]; then echo "ok: 6 files, program v0.33.0, made 2026-11-04T10:00:00Z"
  elif [ "$4" = --dry-run ]; then echo "changed: suricata.yaml"; echo "dry run: nothing was changed"
  else echo "restored 6 files"; fi ;;
esac
`

func backupEnv(t *testing.T) *env {
	t.Helper()
	return setup(t, func(c *Config, dir string) {
		path := filepath.Join(dir, "users.json")
		if err := os.WriteFile(path, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = path
		script := filepath.Join(dir, "ctl")
		if err := os.WriteFile(script, []byte(backupCtlScript), 0o755); err != nil {
			t.Fatal(err)
		}
		c.Ctl = &ctl.Runner{Path: script}
		arch := filepath.Join(dir, "archives")
		if err := os.MkdirAll(arch, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(arch, "dpistack-backup-20261104T100000Z.tar.gz"), []byte("GZIPDATA"), 0o640); err != nil {
			t.Fatal(err)
		}
		c.BackupsDir = arch
		c.Audit = &audit.Log{Path: filepath.Join(dir, "audit.jsonl")}
	})
}

const arc = "dpistack-backup-20261104T100000Z.tar.gz"

func TestBackupsListAndCreate(t *testing.T) {
	e := backupEnv(t)
	w := e.as("admin", "GET", "/api/backups", "")
	if w.Code != 200 {
		t.Fatalf("list: %d %s", w.Code, w.Body)
	}
	var got struct {
		Backups  []ctl.BackupInfo `json:"backups"`
		Download bool             `json:"download"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Backups) != 1 || got.Backups[0].Files != 6 || got.Backups[0].Program != "0.33.0" || !got.Download {
		t.Errorf("list = %+v", got)
	}
	w = e.as("admin", "POST", "/api/backups", `{}`)
	var made struct {
		OK   bool   `json:"ok"`
		Name string `json:"name"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &made)
	if w.Code != 200 || !made.OK || made.Name != "dpistack-backup-20261104T101500Z.tar.gz" {
		t.Errorf("create: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "backup create\n") {
		t.Errorf("calls: %q", e.calls())
	}
}

func TestBackupsVerifyAndTheTwoKindsOfFailure(t *testing.T) {
	e := backupEnv(t)
	w := e.as("admin", "POST", "/api/backups/"+arc+"/verify", `{}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "ok: 6 files") {
		t.Fatalf("verify: %d %s", w.Code, w.Body)
	}
	if err := os.WriteFile(filepath.Join(e.dir, "BAD"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	w = e.as("admin", "POST", "/api/backups/"+arc+"/verify", `{}`)
	var bad struct{ Error, Output string }
	_ = json.Unmarshal(w.Body.Bytes(), &bad)
	if w.Code != http.StatusConflict || !strings.Contains(bad.Output, "suricata -T failed") || bad.Error == "" {
		t.Errorf("a failed check: %d %s", w.Code, w.Body)
	}
	_ = os.Remove(filepath.Join(e.dir, "BAD"))
	if err := os.WriteFile(filepath.Join(e.dir, "GONE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if w = e.as("admin", "POST", "/api/backups/"+arc+"/verify", `{}`); w.Code != http.StatusNotFound {
		t.Errorf("a missing archive: %d %s", w.Code, w.Body)
	}
}

func TestRestoreNeedsADryRunOrAnAcknowledgement(t *testing.T) {
	e := backupEnv(t)
	w := e.as("admin", "POST", "/api/backups/"+arc+"/restore", `{}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("a bare restore: %d %s", w.Code, w.Body)
	}
	if strings.Contains(e.calls(), "restore") {
		t.Fatalf("ctl was called anyway: %q", e.calls())
	}
	w = e.as("admin", "POST", "/api/backups/"+arc+"/restore", `{"dry_run":true}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "changed: suricata.yaml") || !strings.Contains(e.calls(), "restore "+arc+" --dry-run") {
		t.Errorf("dry run: %d %s calls %q", w.Code, w.Body, e.calls())
	}
	w = e.as("admin", "POST", "/api/backups/"+arc+"/restore", `{"acknowledged":true}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "restored 6 files") {
		t.Errorf("restore: %d %s", w.Code, w.Body)
	}
	if !strings.Contains(e.calls(), "restore "+arc+"\n") {
		t.Errorf("the real restore was not asked: %q", e.calls())
	}
}

func TestBackupNamesAreBareFileNames(t *testing.T) {
	e := backupEnv(t)
	for _, name := range []string{"x.zip", "a%20b.tar.gz", "..%2fetc%2fpasswd", "..%2f..%2fx.tar.gz", ".hidden.tar.gz", "a..b.tar.gz"} {
		for _, p := range []string{"/api/backups/" + name, "/api/backups/" + name + "/verify", "/api/backups/" + name + "/restore"} {
			method := "POST"
			if !strings.Contains(p[len("/api/backups/"):], "/") {
				method = "GET"
			}
			w := e.as("admin", method, p, `{"dry_run":true}`)
			if w.Code != http.StatusBadRequest && w.Code != http.StatusNotFound {
				t.Errorf("%s %s: %d", method, p, w.Code)
			}
		}
	}
	if e.calls() != "" {
		t.Errorf("ctl was called for a bad name: %q", e.calls())
	}
}

func TestBackupDownload(t *testing.T) {
	e := backupEnv(t)
	w := e.as("admin", "GET", "/api/backups/"+arc, "")
	if w.Code != 200 || w.Body.String() != "GZIPDATA" {
		t.Fatalf("download: %d %q", w.Code, w.Body)
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/gzip" {
		t.Errorf("Content-Type %q", ct)
	}
	if cd := w.Header().Get("Content-Disposition"); !strings.Contains(cd, "attachment") || !strings.Contains(cd, arc) {
		t.Errorf("Content-Disposition %q", cd)
	}
	if w = e.as("admin", "GET", "/api/backups/dpistack-backup-none.tar.gz", ""); w.Code != http.StatusNotFound {
		t.Errorf("a missing file: %d", w.Code)
	}
}

func TestBackupDownloadFollowsNoLink(t *testing.T) {
	e := backupEnv(t)
	secret := filepath.Join(e.dir, "secret.txt")
	if err := os.WriteFile(secret, []byte("TOPSECRET"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(e.dir, "archives", "link.tar.gz")); err != nil {
		t.Fatal(err)
	}
	w := e.as("admin", "GET", "/api/backups/link.tar.gz", "")
	if w.Code != http.StatusNotFound || strings.Contains(w.Body.String(), "TOPSECRET") {
		t.Errorf("a symlink: %d %s", w.Code, w.Body)
	}
}

func TestBackupDownloadIsOffWithoutADirectory(t *testing.T) {
	e := setup(t, func(c *Config, dir string) {
		path := filepath.Join(dir, "users.json")
		if err := os.WriteFile(path, []byte(usersJSON(false)), 0o640); err != nil {
			t.Fatal(err)
		}
		c.UsersFile = path
	})
	if w := e.as("admin", "GET", "/api/backups/"+arc, ""); w.Code != http.StatusNotFound {
		t.Errorf("no directory: %d %s", w.Code, w.Body)
	}
}

func TestBackupsNeedThePermission(t *testing.T) {
	e := backupEnv(t)
	for _, u := range []string{"vi", "an", "op", "cu"} {
		for _, rt := range []struct{ method, path string }{
			{"GET", "/api/backups"}, {"POST", "/api/backups"}, {"GET", "/api/backups/" + arc},
			{"POST", "/api/backups/" + arc + "/verify"}, {"POST", "/api/backups/" + arc + "/restore"},
		} {
			if w := e.as(u, rt.method, rt.path, `{"dry_run":true}`); !isForbidden(w) {
				t.Errorf("%s %s %s: %d", u, rt.method, rt.path, w.Code)
			}
		}
	}
	if e.calls() != "" {
		t.Errorf("ctl was called for a user without the permission: %q", e.calls())
	}
}

func TestRestoreIsAuditedWithTheArchiveAndNoContent(t *testing.T) {
	e := backupEnv(t)
	e.as("admin", "POST", "/api/backups/"+arc+"/restore", `{"dry_run":true}`)
	e.as("admin", "POST", "/api/backups/"+arc+"/restore", `{"acknowledged":true}`)
	var dry, real *audit.Entry
	list := e.auditLines()
	for i := range list {
		if !strings.Contains(list[i].Action, "restore") {
			continue
		}
		if strings.Contains(list[i].Detail, "dry run") {
			dry = &list[i]
		} else {
			real = &list[i]
		}
	}
	if dry == nil || real == nil || real.User != "admin" || !strings.Contains(real.Detail, arc) {
		t.Fatalf("audit lines: %+v", list)
	}
}
