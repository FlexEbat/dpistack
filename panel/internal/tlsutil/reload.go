// Package tlsutil serves the panel over HTTPS (PANEL_TLS). The certificate
// is read from files and read again when either file changes, so a renewal
// by the watchdog or by certbot needs no restart of the panel.
package tlsutil

import (
	"crypto/sha256"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

// Reloader hands out the certificate of a pair of files and reloads it when
// the modification time of either file changes.
type Reloader struct {
	certFile, keyFile string

	mu      sync.Mutex
	cert    *tls.Certificate
	certMod time.Time
	keyMod  time.Time
}

// NewReloader loads the pair at once: a pair that cannot be used stops the
// panel at start, so that it never runs in plain HTTP by mistake.
func NewReloader(certFile, keyFile string) (*Reloader, error) {
	if certFile == "" || keyFile == "" {
		return nil, errors.New("tls: both a certificate and a key file are needed")
	}
	r := &Reloader{certFile: certFile, keyFile: keyFile}
	if err := r.load(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *Reloader) load() error {
	cm, err := modTime(r.certFile)
	if err != nil {
		return err
	}
	km, err := modTime(r.keyFile)
	if err != nil {
		return err
	}
	pair, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		return fmt.Errorf("tls: %w", err)
	}
	r.cert, r.certMod, r.keyMod = &pair, cm, km
	return nil
}

func modTime(path string) (time.Time, error) {
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}, fmt.Errorf("tls: %w", err)
	}
	return st.ModTime(), nil
}

// GetCertificate is tls.Config.GetCertificate. When the files changed but
// the new pair is not usable yet (the key written, the certificate not yet),
// the old certificate stays and the next handshake tries again.
func (r *Reloader) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	cm, cerr := modTime(r.certFile)
	km, kerr := modTime(r.keyFile)
	if cerr == nil && kerr == nil && (!cm.Equal(r.certMod) || !km.Equal(r.keyMod)) {
		if err := r.load(); err != nil {
			log.Printf("panel: the certificate files changed and cannot be used yet, the old one stays: %v", err)
		} else {
			log.Printf("panel: certificate reloaded, SHA-256 %s", Fingerprint(r.cert))
		}
	}
	return r.cert, nil
}

// Current is the certificate in use.
func (r *Reloader) Current() *tls.Certificate {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cert
}

// Config is the server side TLS configuration: TLS 1.2 and later.
func (r *Reloader) Config() *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS12, GetCertificate: r.GetCertificate}
}

// Fingerprint is the SHA-256 of the leaf certificate as upper case hex pairs
// joined by colons, the form browsers and `openssl x509 -fingerprint` show.
func Fingerprint(c *tls.Certificate) string {
	if c == nil || len(c.Certificate) == 0 {
		return ""
	}
	sum := sha256.Sum256(c.Certificate[0])
	pairs := make([]string, len(sum))
	for i, b := range sum {
		pairs[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(pairs, ":")
}
