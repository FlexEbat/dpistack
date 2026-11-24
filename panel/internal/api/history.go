package api

import (
	"net/http"
	"net/url"
	"regexp"
)

var historyDate = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}$`)

// historyReport handles GET /api/history/report?kind=daily|weekly&date=YYYY-MM-DD:
// the roll-up of one day or of the 7 days ending at the date (default today),
// as `dpistack report` prints it with --json. The watchdog writes the days
// when HISTORY_ENABLE=yes; without them the answer says so (days is empty).
func (s *server) historyReport(w http.ResponseWriter, r *http.Request) {
	// Query() drops a pair it cannot parse (a semicolon, a bad escape) and
	// would run the report with no date: a query that does not parse is refused.
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		writeError(w, http.StatusBadRequest, "the query does not parse")
		return
	}
	kind := q.Get("kind")
	if kind == "" {
		kind = "daily"
	}
	if kind != "daily" && kind != "weekly" {
		writeError(w, http.StatusBadRequest, "kind is daily or weekly")
		return
	}
	date := q.Get("date")
	if date != "" && !historyDate.MatchString(date) {
		writeError(w, http.StatusBadRequest, "date is a day like 2026-11-20")
		return
	}
	out, err := s.cfg.Ctl.Report(r.Context(), kind, date)
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}

// historyDevices handles GET /api/history/devices: the private addresses that
// were seen, with the first and the last day, as a JSON array.
func (s *server) historyDevices(w http.ResponseWriter, r *http.Request) {
	out, err := s.cfg.Ctl.Devices(r.Context())
	if err != nil {
		opError(w, err)
		return
	}
	passJSON(w, out)
}
