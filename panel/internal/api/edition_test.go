package api

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/fstest"
)

// The page always asks for app.css and fx.js; the edition decides which
// file answers, so lite never receives the full stylesheet or the effects.
func TestEditionPicksStylesheetAndScript(t *testing.T) {
	site := fstest.MapFS{
		"full.css": {Data: []byte("FULL-CSS")},
		"lite.css": {Data: []byte("LITE-CSS")},
		"fx.js":    {Data: []byte("FX")},
		"nofx.js":  {Data: []byte("NOFX")},
	}
	for _, tc := range []struct {
		lite    bool
		css, js string
	}{{false, "FULL-CSS", "FX"}, {true, "LITE-CSS", "NOFX"}} {
		h := edition(tc.lite, http.FileServerFS(site))
		for path, want := range map[string]string{"/app.css": tc.css, "/fx.js": tc.js} {
			w := httptest.NewRecorder()
			h.ServeHTTP(w, httptest.NewRequest("GET", path, nil))
			body, _ := io.ReadAll(w.Body)
			if w.Code != 200 || string(body) != want {
				t.Errorf("lite=%v %s: %d %q, want %q", tc.lite, path, w.Code, body, want)
			}
		}
	}
}
