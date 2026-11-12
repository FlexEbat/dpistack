package auth

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"strings"
	"time"
)

// API tokens (tech.md 18.45). A token lets a script call the API without a
// session: `Authorization: Bearer dpt_...`. It is made by `dpistack tokens
// create`, which prints it once and keeps only its SHA-256 in api-tokens.json
// (beside users.json, 0640, written only by that verb). The token is 256 bits
// of randomness, so a plain hash is enough: there is nothing to guess.

// TokenPrefix starts every token, so a wrong kind of secret is turned away
// without reading the file.
const TokenPrefix = "dpt_"

// ScopeRead is the one scope that is not a role: the token may do what its
// owner may read (GET and HEAD), and nothing else.
const ScopeRead = "read"

const maxTokensFile = 1 << 20

// Token is one entry of api-tokens.json. It never holds the secret.
type Token struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	User    string `json:"user"`
	Scope   string `json:"scope"` // "read" or the name of a preset role
	Hash    string `json:"hash"`
	Created string `json:"created"`
	Expires string `json:"expires"`
}

// HashToken is the form in which a token is kept.
func HashToken(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// Tokens reads api-tokens.json.
type Tokens struct {
	File string
	Now  func() time.Time
}

func (t *Tokens) now() time.Time {
	if t.Now != nil {
		return t.Now()
	}
	return time.Now()
}

// List returns every token, expired ones included. No file is an empty list.
func (t *Tokens) List() ([]Token, error) {
	if t == nil || t.File == "" {
		return nil, nil
	}
	data, err := os.ReadFile(t.File)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read api-tokens.json: %w", err)
	}
	if len(data) > maxTokensFile {
		return nil, errors.New("api-tokens.json is too large")
	}
	var doc struct {
		Tokens []Token `json:"tokens"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("api-tokens.json: %w", err)
	}
	return doc.Tokens, nil
}

// Expired reports whether a token is past its time. A time that cannot be
// read counts as expired.
func (tk Token) Expired(now time.Time) bool {
	exp, err := time.Parse(time.RFC3339, tk.Expires)
	return err != nil || !now.Before(exp)
}

// Lookup finds the live token of a secret. Every entry is compared, whatever
// the secret is, so the time does not say how far a guess got.
func (t *Tokens) Lookup(secret string) (Token, bool, error) {
	if !strings.HasPrefix(secret, TokenPrefix) || len(secret) > 128 {
		return Token{}, false, nil
	}
	list, err := t.List()
	if err != nil {
		return Token{}, false, err
	}
	want := []byte(HashToken(secret))
	var found Token
	ok := false
	for _, tk := range list {
		if subtle.ConstantTimeCompare([]byte(tk.Hash), want) == 1 {
			found, ok = tk, true
		}
	}
	if !ok || found.Expired(t.now()) {
		return Token{}, false, nil
	}
	return found, true, nil
}

// TokenUser is the account a request with the token acts as: the owner, with
// the permissions of the scope but never more than the owner holds now. A
// read token keeps all the owner's permissions and the API refuses every
// method that changes anything.
func TokenUser(tk Token, owner User) User {
	have := owner.Effective()
	perms := have
	if tk.Scope != ScopeRead {
		perms = nil
		for _, p := range RolePerms(tk.Scope) {
			if slices.Contains(have, p) {
				perms = append(perms, p)
			}
		}
	}
	return User{Name: owner.Name, Role: roleCustom, Perms: perms}
}
