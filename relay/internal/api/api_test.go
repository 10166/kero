package api

import (
	"encoding/base64"
	"testing"
)

func TestOAuthStateRejectsTampering(t *testing.T) {
	key := []byte("01234567890123456789012345678901")
	sealed := sealState([]byte("state"), key)
	payload, ok := openState(sealed, key)
	if !ok || string(payload) != "state" {
		t.Fatal("valid OAuth state did not round trip")
	}
	bytes, err := base64.RawURLEncoding.DecodeString(sealed)
	if err != nil {
		t.Fatal(err)
	}
	bytes[len(bytes)-1] ^= 1
	if _, ok := openState(base64.RawURLEncoding.EncodeToString(bytes), key); ok {
		t.Fatal("tampered OAuth state was accepted")
	}
}

func TestDeviceValidation(t *testing.T) {
	if !validUUID("00112233-4455-6677-8899-aabbccddeeff") {
		t.Fatal("valid UUID rejected")
	}
	if validUUID("00112233-4455-6677-8899-aabbccddeefg") {
		t.Fatal("invalid UUID accepted")
	}
	key := base64.StdEncoding.EncodeToString(make([]byte, 32))
	if !validDeviceKey(key) || validDeviceKey(base64.StdEncoding.EncodeToString(make([]byte, 31))) {
		t.Fatal("device key length validation failed")
	}
}
