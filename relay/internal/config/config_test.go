package config

import "testing"

func TestLoadRequiresSecureRelayURL(t *testing.T) {
	t.Setenv("KERO_GOOGLE_CLIENT_ID", "client")
	t.Setenv("KERO_GOOGLE_CLIENT_SECRET", "secret")
	t.Setenv("KERO_TOKEN_SECRET", "01234567890123456789012345678901")

	for _, relayURL := range []string{
		"https://relay.example.com",
		"http://localhost:8080",
		"http://127.0.0.1:8080",
		"http://[::1]:8080",
	} {
		t.Run(relayURL, func(t *testing.T) {
			t.Setenv("KERO_RELAY_BASE_URL", relayURL)
			if _, err := Load(); err != nil {
				t.Fatalf("secure relay URL was rejected: %v", err)
			}
		})
	}

	for _, relayURL := range []string{
		"http://relay.example.com",
		"ftp://relay.example.com",
		"not-a-url",
	} {
		t.Run(relayURL, func(t *testing.T) {
			t.Setenv("KERO_RELAY_BASE_URL", relayURL)
			if _, err := Load(); err == nil {
				t.Fatal("insecure relay URL was accepted")
			}
		})
	}
}

func TestLoadRequiresLongTokenSecret(t *testing.T) {
	t.Setenv("KERO_RELAY_BASE_URL", "https://relay.example.com")
	t.Setenv("KERO_GOOGLE_CLIENT_ID", "client")
	t.Setenv("KERO_GOOGLE_CLIENT_SECRET", "secret")
	t.Setenv("KERO_TOKEN_SECRET", "too-short")
	if _, err := Load(); err == nil {
		t.Fatal("short token secret was accepted")
	}
}
