package tlsutil

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writePair writes a new self-signed pair and gives both files the time mt.
func writePair(t *testing.T, dir, cn string, mt time.Time) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	kder, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	cert := filepath.Join(dir, "panel.crt")
	keyf := filepath.Join(dir, "panel.key")
	if err := os.WriteFile(cert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keyf, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kder}), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{cert, keyf} {
		if err := os.Chtimes(f, mt, mt); err != nil {
			t.Fatal(err)
		}
	}
	return cert, keyf
}

func TestReloaderLoadsAndReloads(t *testing.T) {
	dir := t.TempDir()
	cert, key := writePair(t, dir, "first", time.Now().Add(-2*time.Hour))
	r, err := NewReloader(cert, key)
	if err != nil {
		t.Fatal(err)
	}
	c1, _ := r.GetCertificate(nil)
	f1 := Fingerprint(c1)
	if f1 == "" || strings.Count(f1, ":") != 31 {
		t.Fatalf("fingerprint %q is not 32 hex pairs", f1)
	}
	if again, _ := r.GetCertificate(nil); Fingerprint(again) != f1 {
		t.Fatal("an unchanged pair must give the same certificate")
	}
	writePair(t, dir, "second", time.Now())
	c2, _ := r.GetCertificate(nil)
	if Fingerprint(c2) == f1 {
		t.Fatal("a changed pair must be read again without a restart")
	}
}

func TestReloaderKeepsOldCertificateOnABadPair(t *testing.T) {
	dir := t.TempDir()
	cert, key := writePair(t, dir, "first", time.Now().Add(-2*time.Hour))
	r, err := NewReloader(cert, key)
	if err != nil {
		t.Fatal(err)
	}
	want := Fingerprint(r.Current())
	// The key is replaced first, the certificate has not arrived yet.
	other := t.TempDir()
	_, otherKey := writePair(t, other, "other", time.Now())
	data, _ := os.ReadFile(otherKey)
	if err := os.WriteFile(key, data, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := r.GetCertificate(nil)
	if err != nil || Fingerprint(got) != want {
		t.Fatalf("a mismatched pair must leave the old certificate, got %q err %v", Fingerprint(got), err)
	}
	// The certificate arrives: the next handshake takes the pair.
	otherCert := filepath.Join(other, "panel.crt")
	cdata, _ := os.ReadFile(otherCert)
	if err := os.WriteFile(cert, cdata, 0o644); err != nil {
		t.Fatal(err)
	}
	got, _ = r.GetCertificate(nil)
	if Fingerprint(got) == want {
		t.Fatal("the completed pair must be taken")
	}
}

func TestNewReloaderRefusesAnUnusablePair(t *testing.T) {
	dir := t.TempDir()
	if _, err := NewReloader("", ""); err == nil {
		t.Fatal("empty paths must be refused")
	}
	if _, err := NewReloader(filepath.Join(dir, "no.crt"), filepath.Join(dir, "no.key")); err == nil {
		t.Fatal("missing files must be refused")
	}
	cert, key := writePair(t, dir, "x", time.Now())
	if err := os.WriteFile(key, []byte("not a key"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewReloader(cert, key); err == nil {
		t.Fatal("a broken key must be refused")
	}
}

func TestConfigRefusesOldProtocols(t *testing.T) {
	dir := t.TempDir()
	cert, key := writePair(t, dir, "x", time.Now())
	r, err := NewReloader(cert, key)
	if err != nil {
		t.Fatal(err)
	}
	if r.Config().MinVersion < 0x0303 {
		t.Fatal("TLS 1.2 is the oldest version served")
	}
}
