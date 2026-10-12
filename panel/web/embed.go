// Package web carries the panel's static files inside the binary, so
// PANEL_SOURCE=prebuilt installs one file (tech.md 4.2).
package web

import "embed"

// Files is the static site served at /.
//
//go:embed index.html app.css app.js
var Files embed.FS
