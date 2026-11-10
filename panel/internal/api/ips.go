package api

import (
	"encoding/json"
	"net/http"
	"regexp"
)

// The IPS page (tech.md 18.42). Both routes run one verb and send its JSON on
// as it is, so the page and `dpistack ips status|test` show the same thing.
var pcapName = regexp.MustCompile(`^[a-z0-9_-]{1,40}$`)

// ipsStatus handles GET /api/ips.
func (s *server) ipsStatus(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.IPSStatus(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// ipsTest handles POST /api/ips/test with {"sids":[...],"pcap":"name"}, both
// optional. It replays a shipped pcap offline; nothing live is touched. One
// test runs at a time, because loading the rule set is heavy.
func (s *server) ipsTest(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Sids []json.Number `json:"sids"`
		Pcap string        `json:"pcap"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil && err.Error() != "EOF" {
		writeError(w, http.StatusBadRequest, "the body is {\"sids\":[1000001],\"pcap\":\"bittorrent\"}, both optional")
		return
	}
	if len(body.Sids) > 20 {
		writeError(w, http.StatusBadRequest, "at most 20 rule numbers at a time")
		return
	}
	sids := make([]string, 0, len(body.Sids))
	for _, n := range body.Sids {
		if !sidNumber.MatchString(n.String()) {
			writeError(w, http.StatusBadRequest, "a rule number is a whole number")
			return
		}
		sids = append(sids, n.String())
	}
	if body.Pcap != "" && !pcapName.MatchString(body.Pcap) {
		writeError(w, http.StatusBadRequest, "the pcap is a short name, not a path")
		return
	}
	if !s.ops.begin(&s.ops.ipsTestBusy) {
		writeError(w, http.StatusConflict, "a rule test is already running")
		return
	}
	defer s.ops.end(&s.ops.ipsTestBusy)
	out, err := s.cfg.Ctl.IPSTest(r.Context(), sids, body.Pcap)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}
