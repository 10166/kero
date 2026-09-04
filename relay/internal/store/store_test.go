package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"
)

const testDeviceID = "00112233-4455-6677-8899-aabbccddeeff"

func TestSessionsAreDeviceBoundAndRevocationInvalidatesThem(t *testing.T) {
	ctx := context.Background()
	store, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	for _, account := range []string{"account-a", "account-b"} {
		if err := store.EnsureAccount(ctx, account); err != nil {
			t.Fatal(err)
		}
		if err := store.EnrollDevice(ctx, account, Device{
			ID: testDeviceID, AgreementKey: "agreement", SigningKey: "signing",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if !store.DeviceBelongsTo(ctx, "account-a", testDeviceID) ||
		!store.DeviceBelongsTo(ctx, "account-b", testDeviceID) {
		t.Fatal("the same local device ID should be independently scoped per account")
	}

	expiry := time.Now().Add(time.Hour)
	if err := store.PutSession(ctx, "access-secret", "account-a", testDeviceID, "access", expiry); err != nil {
		t.Fatal(err)
	}
	if err := store.PutSession(ctx, "refresh-secret", "account-a", testDeviceID, "refresh", expiry); err != nil {
		t.Fatal(err)
	}
	account, device, err := store.Authenticate(ctx, "access-secret")
	if err != nil || account != "account-a" || device != testDeviceID {
		t.Fatalf("unexpected authentication result: %q %q %v", account, device, err)
	}

	if err := store.RevokeDevice(ctx, "account-a", testDeviceID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Authenticate(ctx, "access-secret"); err == nil {
		t.Fatal("revoked device retained access")
	}
	if _, _, err := store.ConsumeRefresh(ctx, "refresh-secret"); err == nil {
		t.Fatal("revoked device retained refresh access")
	}
	if !store.DeviceBelongsTo(ctx, "account-b", testDeviceID) {
		t.Fatal("revoking one account affected another account")
	}
}

func TestLoginGrantIsOneTimeAndTokensAreHashed(t *testing.T) {
	ctx := context.Background()
	store, err := Open(filepath.Join(t.TempDir(), "relay.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if err := store.EnsureAccount(ctx, "account"); err != nil {
		t.Fatal(err)
	}
	if err := store.PutLoginGrant(
		ctx, HashToken("grant"), "account", "challenge", "kero://remote-auth",
		time.Now().Add(time.Minute),
	); err != nil {
		t.Fatal(err)
	}
	account, challenge, err := store.ConsumeLoginGrant(ctx, HashToken("grant"))
	if err != nil || account != "account" || challenge != "challenge" {
		t.Fatalf("unexpected grant result: %q %q %v", account, challenge, err)
	}
	if _, _, err := store.ConsumeLoginGrant(ctx, HashToken("grant")); err == nil {
		t.Fatal("login grant was reusable")
	}

	if err := store.EnrollDevice(ctx, "account", Device{ID: testDeviceID}); err != nil {
		t.Fatal(err)
	}
	if err := store.PutSession(ctx, "plaintext-token", "account", testDeviceID, "access", time.Now().Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := store.db.QueryRowContext(
		ctx, `SELECT COUNT(*) FROM sessions WHERE token_hash=?`, "plaintext-token",
	).Scan(&count); err != nil && err != sql.ErrNoRows {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatal("session token was stored in plaintext")
	}
}
