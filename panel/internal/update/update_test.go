package update

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestNewer(t *testing.T) {
	cases := []struct {
		cur, latest string
		want        bool
	}{
		{"0.25.2", "v0.25.3", true},
		{"0.25.2", "v0.26.0", true},
		{"0.25.2", "v1.0.0", true},
		{"0.25.2", "v0.25.2", false},
		{"0.25.2", "v0.25.1", false},
		{"0.25.10", "v0.25.9", false},
		{"0.9.0", "v0.10.0", true},
		{"0.25.2", "latest", false},
		{"dev", "v0.25.3", false},
	}
	for _, c := range cases {
		if got := Newer(c.cur, c.latest); got != c.want {
			t.Errorf("Newer(%q,%q)=%v want %v", c.cur, c.latest, got, c.want)
		}
	}
}

func server(t *testing.T, body string, code int, hits *atomic.Int32) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(code)
		_, _ = w.Write([]byte(body))
	}))
}

func TestGetFindsAnUpdateAndCaches(t *testing.T) {
	var hits atomic.Int32
	srv := server(t, `{"tag_name":"v0.26.0","html_url":"https://github.com/FlexEbat/dpistack/releases/tag/v0.26.0"}`, 200, &hits)
	defer srv.Close()
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	c := &Checker{Current: "0.25.2", URL: srv.URL, Now: func() time.Time { return now }}
	info := c.Get(context.Background())
	if !info.Available || info.Latest != "0.26.0" || info.Current != "0.25.2" {
		t.Fatalf("info = %+v", info)
	}
	if info.ReleaseURL == "" {
		t.Fatal("release url dropped")
	}
	c.Get(context.Background())
	if hits.Load() != 1 {
		t.Fatalf("hits = %d, the answer must be cached", hits.Load())
	}
	now = now.Add(TTL + time.Minute)
	c.Get(context.Background())
	if hits.Load() != 2 {
		t.Fatalf("hits = %d, the cache must expire", hits.Load())
	}
}

func TestGetSameVersionIsNoUpdate(t *testing.T) {
	var hits atomic.Int32
	srv := server(t, `{"tag_name":"v0.25.2","html_url":"https://github.com/FlexEbat/dpistack/releases/tag/v0.25.2"}`, 200, &hits)
	defer srv.Close()
	c := &Checker{Current: "0.25.2", URL: srv.URL}
	if info := c.Get(context.Background()); info.Available || info.Error != "" {
		t.Fatalf("info = %+v", info)
	}
}

func TestGetFailuresAreAnswersNotErrors(t *testing.T) {
	var hits atomic.Int32
	for _, tc := range []struct {
		name, body string
		code       int
	}{
		{"server error", `oops`, 500},
		{"not json", `<html>`, 200},
		{"bad tag", `{"tag_name":"nightly"}`, 200},
	} {
		srv := server(t, tc.body, tc.code, &hits)
		c := &Checker{Current: "0.25.2", URL: srv.URL}
		info := c.Get(context.Background())
		srv.Close()
		if info.Available || info.Error == "" {
			t.Errorf("%s: info = %+v", tc.name, info)
		}
	}
}

func TestForeignReleasePageIsDropped(t *testing.T) {
	var hits atomic.Int32
	srv := server(t, `{"tag_name":"v0.26.0","html_url":"https://evil.example/x"}`, 200, &hits)
	defer srv.Close()
	c := &Checker{Current: "0.25.2", URL: srv.URL}
	if info := c.Get(context.Background()); info.ReleaseURL != "" || !info.Available {
		t.Fatalf("info = %+v", info)
	}
}

func TestOffMakesNoRequest(t *testing.T) {
	var hits atomic.Int32
	srv := server(t, `{}`, 200, &hits)
	defer srv.Close()
	c := &Checker{Current: "0.25.2", URL: "off"}
	if info := c.Get(context.Background()); info.Available || info.Latest != "" {
		t.Fatalf("info = %+v", info)
	}
	if hits.Load() != 0 {
		t.Fatal("a request was made")
	}
}
