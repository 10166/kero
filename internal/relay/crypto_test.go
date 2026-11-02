package relay

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"testing"
)

func vectorIdentity(t *testing.T, id, key string) *Identity {
	t.Helper()
	raw, err := hex.DecodeString(key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := ecdh.X25519().NewPrivateKey(raw)
	if err != nil {
		t.Fatal(err)
	}
	return &Identity{ID: id, agreement: private, signing: ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))}
}

// This frame was generated independently with Python cryptography from RFC
// 7748's X25519 keys, HKDF-SHA256, and ChaCha20-Poly1305 (nonce 00..0b).
func TestSwiftFrameVectorAndReplay(t *testing.T) {
	alice := vectorIdentity(t, "00112233-4455-6677-8899-aabbccddeeff", "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := vectorIdentity(t, "10213243-5465-7687-98a9-bacbdcedfe0f", "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	key, err := pairKey(alice, bob.Record())
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(key) != "1457b5b9fa3bbf5a41278c83a1c309023d932c02e7ebeb51231c6f58d9188868" {
		t.Fatalf("pair key: %x", key)
	}
	frame, err := hex.DecodeString("0107102132435465768798a9bacbdcedfe0f00112233445566778899aabbccddeeff12345678123443218765123456789abc000000000000002a000102030405060708090a0b03e59ab0928c3889718265a875a87568f372386d9b8c4912f84e5d")
	if err != nil {
		t.Fatal(err)
	}
	cipher := NewCipher(bob)
	forged := append([]byte(nil), frame...)
	forged[57] = 100
	if _, _, err := cipher.Open(forged, alice.Record()); err == nil {
		t.Fatal("accepted forged frame")
	}
	f, plaintext, err := cipher.Open(frame, alice.Record())
	if err != nil {
		t.Fatal(err)
	}
	if f.Sequence != 42 || f.Kind != KindInput || f.StreamID != "12345678-1234-4321-8765-123456789abc" || !bytes.Equal(plaintext, []byte("hello relay")) {
		t.Fatalf("unexpected frame: %+v %q", f, plaintext)
	}
	if _, _, err := cipher.Open(frame, alice.Record()); !errors.Is(err, ErrReplay) {
		t.Fatalf("replay: %v", err)
	}
	wrong := alice.Record()
	wrong.ID = bob.ID
	if _, _, err := NewCipher(bob).Open(frame, wrong); !errors.Is(err, ErrWrongRoute) {
		t.Fatalf("route: %v", err)
	}
}

func TestIdentitySwiftRepresentation(t *testing.T) {
	store := newMemoryStore()
	store.data["device-identity"] = []byte(`{"id":"00112233-4455-6677-8899-AABBCCDDEEFF","agreementPrivateKey":"dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=","signingPrivateKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}`)
	identity, err := LoadOrCreateIdentity(store)
	if err != nil {
		t.Fatal(err)
	}
	if identity.ID != "00112233-4455-6677-8899-aabbccddeeff" {
		t.Fatal(identity.ID)
	}
	key, err := base64.StdEncoding.DecodeString(identity.Record().AgreementKey)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(key) != "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" {
		t.Fatalf("public key %x", key)
	}
	store.data["device-identity"] = []byte(`{}`)
	if _, err := LoadOrCreateIdentity(store); err == nil {
		t.Fatal("replaced invalid identity")
	}
}

func TestSealSequencesAndBounds(t *testing.T) {
	alice := vectorIdentity(t, "00112233-4455-6677-8899-aabbccddeeff", "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := vectorIdentity(t, "10213243-5465-7687-98a9-bacbdcedfe0f", "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	sender, receiver := NewCipher(alice), NewCipher(bob)
	stream := "12345678-1234-4321-8765-123456789abc"
	for seq := uint64(0); seq < 2; seq++ {
		wire, err := sender.Seal([]byte("input"), KindInput, bob.Record(), stream)
		if err != nil {
			t.Fatal(err)
		}
		frame, data, err := receiver.Open(wire, alice.Record())
		if err != nil {
			t.Fatal(err)
		}
		if frame.Sequence != seq || string(data) != "input" {
			t.Fatalf("sequence or plaintext: %+v %q", frame, data)
		}
	}
	if _, err := sender.Seal(make([]byte, MaxFrameBytes-FrameHeaderLength-FrameOverhead+1), KindInput, bob.Record(), stream); !errors.Is(err, ErrInvalidFrame) {
		t.Fatalf("oversize frame: %v", err)
	}
}
