// Package auth holds the panel's login checks: the argon2id password hash,
// sessions, the login attempt limiter and the client address policy.
package auth

import (
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"

	"golang.org/x/crypto/argon2"
)

// maxMemoryKiB caps the argon2 memory a hash may demand. The panel unit
// has MemoryMax=64M (tech.md 9), so a 64 MiB hash would be killed by the
// cgroup while it is being checked.
const maxMemoryKiB = 32 * 1024

// maxPasswordLen keeps a huge request body from reaching argon2.
const maxPasswordLen = 512

var (
	// ErrNoPassword means panel.auth does not exist or is empty.
	ErrNoPassword = errors.New("panel password is not set")
	// ErrHashFormat means panel.auth does not hold an argon2id PHC string.
	ErrHashFormat = errors.New("panel.auth is not a supported argon2id hash")
	// ErrHashTooHeavy means the hash asks for more memory than the panel may use.
	ErrHashTooHeavy = errors.New("panel.auth hash needs more memory than the panel budget allows")
)

// hashSlot lets one verification run at a time, so parallel logins cannot
// multiply the argon2 memory.
var hashSlot = make(chan struct{}, 1)

// VerifyFile reads the PHC string from path and checks password against it.
// The file is read on every call, so `ctl panel-passwd` takes effect without
// a panel restart.
func VerifyFile(path, password string) (bool, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, ErrNoPassword
	}
	if err != nil {
		return false, fmt.Errorf("read panel.auth: %w", err)
	}
	phc := strings.TrimSpace(string(data))
	if phc == "" {
		return false, ErrNoPassword
	}
	return Verify(phc, password)
}

// Verify checks password against a PHC string as written by the `argon2`
// CLI with -e: $argon2id$v=19$m=<KiB>,t=<n>,p=<n>$<salt>$<hash>, with
// unpadded standard base64.
func Verify(phc, password string) (bool, error) {
	parts := strings.Split(phc, "$")
	if len(parts) != 6 || parts[0] != "" || parts[1] != "argon2id" || parts[2] != "v=19" {
		return false, ErrHashFormat
	}
	var m, t, p uint32
	if n, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil || n != 3 {
		return false, ErrHashFormat
	}
	if t < 1 || t > 10 || p < 1 || p > 16 || m < 8*p {
		return false, ErrHashFormat
	}
	if m > maxMemoryKiB {
		return false, ErrHashTooHeavy
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(salt) < 8 {
		return false, ErrHashFormat
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(want) < 16 || len(want) > 64 {
		return false, ErrHashFormat
	}
	if len(password) > maxPasswordLen {
		return false, nil
	}

	hashSlot <- struct{}{}
	got := argon2.IDKey([]byte(password), salt, t, m, uint8(p), uint32(len(want)))
	<-hashSlot
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}
