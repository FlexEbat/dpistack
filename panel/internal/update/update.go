// Package update asks GitHub whether a newer dpistack release exists. It only
// reads the public "latest release" document; installing is the job of the
// root verb `dpistack self-update`, never of this package.
package update

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// DefaultURL is the "latest release" document of the project.
const DefaultURL = "https://api.github.com/repos/FlexEbat/dpistack/releases/latest"

const (
	// TTL is how long an answer is reused: the unauthenticated GitHub API
	// allows 60 requests an hour per address, and a release is not urgent.
	TTL = 6 * time.Hour
	// FailTTL is the pause after a failed check.
	FailTTL     = 15 * time.Minute
	maxDocBytes = 1 << 20
)

var tagRE = regexp.MustCompile(`^v?([0-9]+)\.([0-9]+)\.([0-9]+)$`)

// Info is what the panel shows.
type Info struct {
	Current    string    `json:"version"`
	Latest     string    `json:"latest,omitempty"`
	Available  bool      `json:"update_available"`
	ReleaseURL string    `json:"release_url,omitempty"`
	CheckedAt  time.Time `json:"checked_at,omitempty"`
	Error      string    `json:"check_error,omitempty"`
}

// Checker caches the answer of one release document.
type Checker struct {
	Current string // "0.25.2", the version of this panel
	URL     string // empty: DefaultURL; "off" disables the check
	Client  *http.Client
	Now     func() time.Time

	mu   sync.Mutex
	info Info
	next time.Time
}

// Parse reads "v1.2.3" or "1.2.3".
func Parse(v string) ([3]int, bool) {
	m := tagRE.FindStringSubmatch(strings.TrimSpace(v))
	if m == nil {
		return [3]int{}, false
	}
	var out [3]int
	for i := range out {
		n, err := strconv.Atoi(m[i+1])
		if err != nil {
			return [3]int{}, false
		}
		out[i] = n
	}
	return out, true
}

// Newer reports whether latest is a higher version than current. A version
// that does not parse is never newer.
func Newer(current, latest string) bool {
	c, ok1 := Parse(current)
	l, ok2 := Parse(latest)
	if !ok1 || !ok2 {
		return false
	}
	for i := range c {
		if l[i] != c[i] {
			return l[i] > c[i]
		}
	}
	return false
}

func (c *Checker) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// Get returns the cached answer or asks GitHub once the cache is old. It
// never fails: a failed check is an Info with Error set and no update.
func (c *Checker) Get(ctx context.Context) Info {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.URL == "off" {
		return Info{Current: c.Current}
	}
	if !c.next.IsZero() && c.now().Before(c.next) {
		return c.info
	}
	info := Info{Current: c.Current, CheckedAt: c.now().UTC()}
	tag, page, err := c.fetch(ctx)
	if err != nil {
		info.Error = err.Error()
		c.info, c.next = info, c.now().Add(FailTTL)
		return info
	}
	info.Latest = strings.TrimPrefix(tag, "v")
	info.ReleaseURL = page
	info.Available = Newer(c.Current, tag)
	c.info, c.next = info, c.now().Add(TTL)
	return info
}

// Refresh drops the cache so that the next Get asks again.
func (c *Checker) Refresh() {
	c.mu.Lock()
	c.next = time.Time{}
	c.mu.Unlock()
}

func (c *Checker) fetch(ctx context.Context) (tag, page string, err error) {
	url := c.URL
	if url == "" {
		url = DefaultURL
	}
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: 8 * time.Second}
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "dpistack-panel/"+c.Current)
	resp, err := client.Do(req)
	if err != nil {
		return "", "", errors.New("could not reach the release server")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("the release server answered %d", resp.StatusCode)
	}
	var doc struct {
		Tag  string `json:"tag_name"`
		Page string `json:"html_url"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, maxDocBytes)).Decode(&doc); err != nil {
		return "", "", errors.New("the release document is not readable")
	}
	if _, ok := Parse(doc.Tag); !ok {
		return "", "", errors.New("the release has no version tag")
	}
	// Only a link to the project's own release page is passed on.
	if !strings.HasPrefix(doc.Page, "https://github.com/FlexEbat/dpistack/") {
		doc.Page = ""
	}
	return doc.Tag, doc.Page, nil
}
