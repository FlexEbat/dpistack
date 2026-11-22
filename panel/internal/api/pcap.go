package api

import (
	"errors"
	"io"
	"mime"
	"net/http"
	"os"
	"time"

	"github.com/FlexEbat/dpistack/panel/internal/ctl"
)

// pcapUploadCap is what the panel will take from the network at most. The
// verb applies PCAP_MAX_MB, which can be lower; this only keeps a client from
// filling the disk before the verb is asked.
const pcapUploadCap = 512 << 20

// pcapAnalyze handles POST /api/pcap/analyze: one capture as the body (the
// raw bytes, Content-Type application/octet-stream or application/vnd.tcpdump.pcap),
// replayed offline with the live rules by `dpistack pcap analyze`. The file is
// kept only for the length of the run, in a 0600 file of the panel's temp
// directory, and deleted afterwards.
func (s *server) pcapAnalyze(w http.ResponseWriter, r *http.Request) {
	mt, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if mt != "application/octet-stream" && mt != "application/vnd.tcpdump.pcap" {
		writeError(w, http.StatusUnsupportedMediaType, "send the capture as it is, Content-Type: application/octet-stream")
		return
	}
	if !s.ops.begin(&s.ops.pcapBusy) {
		writeError(w, http.StatusConflict, "a capture is already being analyzed")
		return
	}
	defer s.ops.end(&s.ops.pcapBusy)
	// An upload and a replay take longer than the server's 30 seconds.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Now().Add(15 * time.Minute))
	_ = rc.SetWriteDeadline(time.Now().Add(ctl.PcapTimeout + 15*time.Minute))

	f, err := os.CreateTemp("", "dpistack-pcap-*.pcap")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create a temporary file")
		return
	}
	name := f.Name()
	defer os.Remove(name)
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		writeError(w, http.StatusInternalServerError, "could not protect the temporary file")
		return
	}
	n, err := io.Copy(f, http.MaxBytesReader(w, r.Body, pcapUploadCap))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	var tooBig *http.MaxBytesError
	if errors.As(err, &tooBig) {
		writeError(w, http.StatusRequestEntityTooLarge, "the capture is over the 512 MiB the panel takes")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "the upload was interrupted")
		return
	}
	if n == 0 {
		writeError(w, http.StatusBadRequest, "the capture is empty")
		return
	}
	out, err := s.cfg.Ctl.PcapAnalyze(r.Context(), name)
	if err != nil {
		opError(w, err)
		return
	}
	auditDetail(r, "pcap analyze")
	passJSON(w, out)
}
