package hub

import (
	"encoding/hex"
	"testing"
)

func TestUUIDString(t *testing.T) {
	raw, err := hex.DecodeString("00112233445566778899aabbccddeeff")
	if err != nil {
		t.Fatal(err)
	}
	if got := uuidString(raw); got != "00112233-4455-6677-8899-aabbccddeeff" {
		t.Fatalf("unexpected UUID: %s", got)
	}
}

func TestPeerKeysAreAccountScoped(t *testing.T) {
	if key("account-a", "device") == key("account-b", "device") {
		t.Fatal("identical device IDs collided across accounts")
	}
}
