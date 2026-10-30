package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/fstest"
)

// The fonts are served by the panel itself (the policy forbids external
// ones): the type must be right even when the host has no mime table, and
// they may be cached, unlike the pages.
func TestStaticServesFontsWithTheirTypeAndCache(t *testing.T) {
	site := fstest.MapFS{
		"fonts/geist.woff2": {Data: []byte("FONT")},
		"index.html":        {Data: []byte("<!doctype html>")},
	}
	h := static(http.FileServerFS(site))

	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/fonts/geist.woff2", nil))
	if w.Code != 200 {
		t.Fatalf("font: %d", w.Code)
	}
	if got := w.Header().Get("Content-Type"); got != "font/woff2" {
		t.Errorf("font type %q, want font/woff2", got)
	}
	if got := w.Header().Get("Cache-Control"); got != "public, max-age=86400" {
		t.Errorf("font cache %q", got)
	}

	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/index.html", nil))
	if got := w.Header().Get("Cache-Control"); got != "no-cache" {
		t.Errorf("page cache %q, want no-cache", got)
	}
}
