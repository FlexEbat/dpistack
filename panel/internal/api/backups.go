package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// backupsList handles GET /api/backups: the archives, newest first.
func (s *server) backupsList(w http.ResponseWriter, r *http.Request) {
	list, err := s.cfg.Ctl.BackupList(r.Context())
	if err != nil {
		backupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"backups": list, "download": s.cfg.BackupsDir != ""})
}

// backupsCreate handles POST /api/backups.
func (s *server) backupsCreate(w http.ResponseWriter, r *http.Request) {
	if !s.ops.begin(&s.ops.backupBusy) {
		writeError(w, http.StatusConflict, "another backup operation is running")
		return
	}
	defer s.ops.end(&s.ops.backupBusy)
	name, out, err := s.cfg.Ctl.BackupCreate(context.WithoutCancel(r.Context()))
	if err != nil {
		backupError(w, err)
		return
	}
	auditDetail(r, name)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "name": name, "output": out})
}

// backupNameOf takes the archive name from the path; anything but a bare file
// name is refused before ctl or the file system see it.
func backupNameOf(w http.ResponseWriter, r *http.Request) (string, bool) {
	name := r.PathValue("name")
	if !ctl.ValidBackupName(name) {
		writeError(w, http.StatusBadRequest, "not an archive name")
		return "", false
	}
	return name, true
}

// backupsDownload handles GET /api/backups/{name}: the archive as a file. The
// panel reads it from its own copy of the archives directory (-backups-dir)
// and follows no link out of it.
func (s *server) backupsDownload(w http.ResponseWriter, r *http.Request) {
	name, ok := backupNameOf(w, r)
	if !ok {
		return
	}
	if s.cfg.BackupsDir == "" {
		writeError(w, http.StatusNotFound, "downloading archives is not set up on this panel")
		return
	}
	path := filepath.Join(s.cfg.BackupsDir, name)
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() {
		writeError(w, http.StatusNotFound, "no such archive")
		return
	}
	f, err := os.Open(path)
	if err != nil {
		writeError(w, http.StatusNotFound, "the archive cannot be read by the panel")
		return
	}
	defer func() { _ = f.Close() }()
	fi, err := f.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "the archive cannot be read")
		return
	}
	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Header().Set("Cache-Control", "no-store")
	http.ServeContent(w, r, name, fi.ModTime(), f)
}

// backupsVerify handles POST /api/backups/{name}/verify.
func (s *server) backupsVerify(w http.ResponseWriter, r *http.Request) {
	name, ok := backupNameOf(w, r)
	if !ok {
		return
	}
	if !s.ops.begin(&s.ops.backupBusy) {
		writeError(w, http.StatusConflict, "another backup operation is running")
		return
	}
	defer s.ops.end(&s.ops.backupBusy)
	out, err := s.cfg.Ctl.BackupVerify(r.Context(), name)
	if err != nil {
		backupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
}

// backupsRestore handles POST /api/backups/{name}/restore with
// {"dry_run":true} (the diff, nothing changes) or {"acknowledged":true} (the
// real restore, which replaces the configuration files). Without one of the
// two the request is refused: a bare POST must not overwrite the configs.
func (s *server) backupsRestore(w http.ResponseWriter, r *http.Request) {
	name, ok := backupNameOf(w, r)
	if !ok {
		return
	}
	var body struct {
		DryRun       bool `json:"dry_run"`
		Acknowledged bool `json:"acknowledged"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "bad request")
		return
	}
	if !body.DryRun && !body.Acknowledged {
		writeError(w, http.StatusBadRequest, "a restore replaces the configuration files: show the difference first (dry_run) or confirm it (acknowledged)")
		return
	}
	if !s.ops.begin(&s.ops.backupBusy) {
		writeError(w, http.StatusConflict, "another backup operation is running")
		return
	}
	defer s.ops.end(&s.ops.backupBusy)
	if body.DryRun {
		auditDetail(r, name+" (dry run)")
	} else {
		auditDetail(r, name)
	}
	_ = http.NewResponseController(w).SetWriteDeadline(s.cfg.Now().Add(ctl.TestTimeout + 60e9))
	out, err := s.cfg.Ctl.BackupRestore(context.WithoutCancel(r.Context()), name, body.DryRun)
	if err != nil {
		backupError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "dry_run": body.DryRun, "output": out})
}

// backupError maps the exit codes of the backup verbs: 3 is an archive or a
// configuration that did not pass its checks (the reason is in the output),
// 4 is an archive that is not there.
func backupError(w http.ResponseWriter, err error) {
	var exit *ctl.ExitError
	if errors.As(err, &exit) {
		switch exit.Code {
		case 3:
			writeJSON(w, http.StatusConflict, map[string]any{"error": errText(err), "output": exit.Output})
			return
		case 4:
			writeError(w, http.StatusNotFound, errText(err))
			return
		}
	}
	opError(w, err)
}
