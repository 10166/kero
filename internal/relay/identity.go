package relay

import (
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// ErrCredentialNotFound is returned by a CredentialStore when a key is absent.
var ErrCredentialNotFound = errors.New("relay credential not found")

// CredentialStore stores sensitive data in an OS credential store. Implementations
// should translate their missing-item error to ErrCredentialNotFound.
type CredentialStore interface {
	Get(key string) ([]byte, error)
	Set(key string, value []byte) error
	Delete(key string) error
}

// Device is the relay's public device record.
type Device struct {
	ID           string `json:"id"`
	AgreementKey string `json:"agreement_key"`
	SigningKey   string `json:"signing_key"`
	LastSeenAt   string `json:"last_seen_at"`
}

// Identity holds a device's private keys. Its record contains only public keys.
type Identity struct {
	ID        string
	agreement *ecdh.PrivateKey
	signing   ed25519.PrivateKey
}

type storedIdentity struct {
	ID                  string `json:"id"`
	AgreementPrivateKey string `json:"agreementPrivateKey"`
	SigningPrivateKey   string `json:"signingPrivateKey"`
}

// LoadOrCreateIdentity uses the same account and representation as the Swift app.
// An unreadable or corrupt existing identity is an error, never a replacement.
func LoadOrCreateIdentity(store CredentialStore) (*Identity, error) {
	if store == nil {
		return nil, errors.New("relay: credential store is required")
	}
	data, err := store.Get("device-identity")
	if err == nil {
		var s storedIdentity
		if err = json.Unmarshal(data, &s); err != nil {
			return nil, fmt.Errorf("relay: decode identity: %w", err)
		}
		id, err := normalizeUUID(s.ID)
		if err != nil {
			return nil, fmt.Errorf("relay: identity ID: %w", err)
		}
		agreement, err := base64.StdEncoding.DecodeString(s.AgreementPrivateKey)
		if err != nil {
			return nil, fmt.Errorf("relay: agreement key: %w", err)
		}
		key, err := ecdh.X25519().NewPrivateKey(agreement)
		if err != nil {
			return nil, fmt.Errorf("relay: agreement key: %w", err)
		}
		seed, err := base64.StdEncoding.DecodeString(s.SigningPrivateKey)
		if err != nil || len(seed) != ed25519.SeedSize {
			return nil, errors.New("relay: invalid signing key")
		}
		return &Identity{ID: id, agreement: key, signing: ed25519.NewKeyFromSeed(seed)}, nil
	}
	if !errors.Is(err, ErrCredentialNotFound) {
		return nil, err
	}
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	_, signing, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	var uuid [16]byte
	if _, err = rand.Read(uuid[:]); err != nil {
		return nil, err
	}
	uuid[6] = uuid[6]&0x0f | 0x40
	uuid[8] = uuid[8]&0x3f | 0x80
	id := uuidString(uuid[:])
	s := storedIdentity{strings.ToUpper(id), base64.StdEncoding.EncodeToString(key.Bytes()), base64.StdEncoding.EncodeToString(signing.Seed())}
	data, err = json.Marshal(s)
	if err != nil {
		return nil, err
	}
	if err = store.Set("device-identity", data); err != nil {
		return nil, err
	}
	return &Identity{ID: id, agreement: key, signing: signing}, nil
}

func (i *Identity) Record() Device {
	return Device{ID: i.ID, AgreementKey: base64.StdEncoding.EncodeToString(i.agreement.PublicKey().Bytes()), SigningKey: base64.StdEncoding.EncodeToString(i.signing.Public().(ed25519.PublicKey))}
}

func parseUUID(s string) ([16]byte, error) {
	var b [16]byte
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return b, errors.New("relay: invalid UUID")
	}
	compact := strings.ReplaceAll(s, "-", "")
	if len(compact) != 32 {
		return b, errors.New("relay: invalid UUID")
	}
	_, err := hex.Decode(b[:], []byte(compact))
	if err != nil {
		return b, errors.New("relay: invalid UUID")
	}
	return b, nil
}
func uuidString(b []byte) string {
	hexID := hex.EncodeToString(b)
	return hexID[:8] + "-" + hexID[8:12] + "-" + hexID[12:16] + "-" + hexID[16:20] + "-" + hexID[20:]
}
func normalizeUUID(s string) (string, error) {
	b, err := parseUUID(s)
	if err != nil {
		return "", err
	}
	return uuidString(b[:]), nil
}
