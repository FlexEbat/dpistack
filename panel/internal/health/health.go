// Package health reads the watchdog's health.json (tech.md 4.6).
package health

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
)

// maxSize keeps a damaged file from filling panel memory; a real one is a few KB.
const maxSize = 1 << 20

// Check is one watchdog check.
type Check struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Value  string `json:"value"`
	Detail string `json:"detail"`
	Since  string `json:"since"`
}

// Report is the content of health.json.
type Report struct {
	TS      string  `json:"ts"`
	Overall string  `json:"overall"`
	Checks  []Check `json:"checks"`
}

// Read parses the file at path. It returns (nil, nil) while the watchdog has
// not written the file yet, which is normal right after an install.
func Read(path string) (*Report, error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("open health.json: %w", err)
	}
	defer f.Close()

	data, err := io.ReadAll(io.LimitReader(f, maxSize+1))
	if err != nil {
		return nil, fmt.Errorf("read health.json: %w", err)
	}
	if len(data) > maxSize {
		return nil, errors.New("health.json is too large")
	}
	return Parse(data)
}

// Parse reads the content of a health.json already in memory.
func Parse(data []byte) (*Report, error) {
	var r Report
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("parse health.json: %w", err)
	}
	if r.Checks == nil {
		r.Checks = []Check{}
	}
	return &r, nil
}
