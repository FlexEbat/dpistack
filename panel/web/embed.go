// Package web carries the panel's static files inside the binary, so
// a ready binary installs as one file (tech.md 4.2).
package web

import "embed"

// Files is the static site served at /.
//
//go:embed index.html app.css app.js modules
var Files embed.FS
