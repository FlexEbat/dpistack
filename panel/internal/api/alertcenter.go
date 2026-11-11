package api

import (
	"encoding/json"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
)

// The Alert Center (tech.md 18.43). It sits beside GET /api/alerts, the feed
// of status changes, which stays as it is. The routes run one verb each and send its
// JSON on as it is; the verb is the only writer of alerts-state.json.
var (
	alertKey      = regexp.MustCompile(`^(watch:[a-z0-9_.-]{1,64}|sid:[0-9]{1,10})$`)
	alertNote     = regexp.MustCompile(`^[A-Za-z0-9 ._:/@+,=-]{0,80}$`)
	alertStates   = map[string]bool{"new": true, "acknowledged": true, "snoozed": true, "resolved": true}
	alertSources  = map[string]bool{"watchdog": true, "suricata": true}
	alertSeverity = map[string]bool{"crit": true, "warn": true, "info": true}
	alertDur      = map[string]bool{"1h": true, "4h": true, "24h": true, "7d": true}
)

// alertCenterList handles GET /api/alert-center?state=&source=&severity=.
func (s *server) alertCenterList(w http.ResponseWriter, r *http.Request) {
	q, perr := url.ParseQuery(r.URL.RawQuery) // a query that does not parse is refused, not half read
	state, source, sev := q.Get("state"), q.Get("source"), q.Get("severity")
	if perr != nil || (state != "" && !alertStates[state]) || (source != "" && !alertSources[source]) || (sev != "" && !alertSeverity[sev]) {
		writeError(w, http.StatusBadRequest, "bad filter: state is new, acknowledged, snoozed or resolved; source is watchdog or suricata; severity is crit, warn or info")
		return
	}
	out, err := s.cfg.Ctl.AlertsList(r.Context(), state, source, sev)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// alertCenterHistory handles GET /api/alert-center/history?limit=.
func (s *server) alertCenterHistory(w http.ResponseWriter, r *http.Request) {
	limit := 0
	q, perr := url.ParseQuery(r.URL.RawQuery)
	if perr != nil {
		writeError(w, http.StatusBadRequest, "the query does not parse")
		return
	}
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 500 {
			writeError(w, http.StatusBadRequest, "limit is a number from 1 to 500")
			return
		}
		limit = n
	}
	out, err := s.cfg.Ctl.AlertsHistory(r.Context(), limit)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// alertCenterAct handles POST /api/alert-center with {action, key, for, note}.
func (s *server) alertCenterAct(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Action string `json:"action"`
		Key    string `json:"key"`
		For    string `json:"for"`
		Note   string `json:"note"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, `the body is {"action":"ack|snooze|resolve|reopen","key":"watch:disk.free","for":"1h","note":""}`)
		return
	}
	switch body.Action {
	case "ack", "resolve", "reopen":
		if body.For != "" {
			writeError(w, http.StatusBadRequest, "for is only for snooze")
			return
		}
	case "snooze":
		if !alertDur[body.For] {
			writeError(w, http.StatusBadRequest, "snooze for 1h, 4h, 24h or 7d")
			return
		}
	default:
		writeError(w, http.StatusBadRequest, "action is ack, snooze, resolve or reopen")
		return
	}
	if !alertKey.MatchString(body.Key) {
		writeError(w, http.StatusBadRequest, "key is watch:<check> or sid:<number>")
		return
	}
	if !alertNote.MatchString(body.Note) {
		writeError(w, http.StatusBadRequest, "the note is 80 characters of letters, digits and . _ : / @ + , = -")
		return
	}
	auditDetail(r, body.Action+" "+body.Key)
	if _, err := s.cfg.Ctl.AlertsAct(r.Context(), body.Action, body.Key, body.For, body.Note, who(r).Name); err != nil {
		opError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
