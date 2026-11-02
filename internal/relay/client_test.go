package relay

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

type memoryStore struct {
	data    map[string][]byte
	failSet bool
}

func newMemoryStore() *memoryStore { return &memoryStore{data: make(map[string][]byte)} }
func (s *memoryStore) Get(key string) ([]byte, error) {
	b, ok := s.data[key]
	if !ok {
		return nil, ErrCredentialNotFound
	}
	return b, nil
}
func (s *memoryStore) Set(key string, value []byte) error {
	if s.failSet {
		return errors.New("keychain unavailable")
	}
	s.data[key] = append([]byte(nil), value...)
	return nil
}
func (s *memoryStore) Delete(key string) error { delete(s.data, key); return nil }

func TestRefreshBoundaries(t *testing.T) {
	status := http.StatusServiceUnavailable
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/auth/refresh" || r.Method != "POST" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(404)
			return
		}
		calls++
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["refresh_token"] != "old-refresh" {
			t.Errorf("refresh request: %v %v", body, err)
		}
		if status != 200 {
			w.WriteHeader(status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"access_token": "new-access", "refresh_token": "new-refresh", "expires_at": time.Now().Add(time.Hour).UTC().Format(time.RFC3339Nano)})
	}))
	defer server.Close()
	store := newMemoryStore()
	client, err := NewClient(server.URL, store, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	old, err := json.Marshal(Tokens{"old-access", "old-refresh", time.Now().Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	store.data[client.tokenKey()] = old
	if _, err := client.AccessToken(context.Background()); err == nil {
		t.Fatal("outage succeeded")
	}
	if string(store.data[client.tokenKey()]) != string(old) {
		t.Fatal("outage discarded refresh token")
	}
	status = 200
	store.failSet = true
	if _, err := client.AccessToken(context.Background()); err == nil || !strings.Contains(err.Error(), "storing rotated credentials") {
		t.Fatalf("rotation failure: %v", err)
	}
	if tok, err := client.Tokens(); err != nil || tok.RefreshToken != "new-refresh" {
		t.Fatalf("rotated token lost: %+v %v", tok, err)
	}
	store.failSet = false
	if token, err := client.AccessToken(context.Background()); err != nil || token != "new-access" {
		t.Fatalf("persist retry: %q %v", token, err)
	}
	if calls != 2 {
		t.Fatalf("rotated token was refreshed again: %d", calls)
	}
	var persisted Tokens
	if err := json.Unmarshal(store.data[client.tokenKey()], &persisted); err != nil || persisted.RefreshToken != "new-refresh" {
		t.Fatalf("persisted token: %+v %v", persisted, err)
	}
}

func TestRefreshUnauthorizedRemovesCredential(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusUnauthorized) }))
	defer server.Close()
	store := newMemoryStore()
	client, err := NewClient(server.URL, store, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(Tokens{"access", "refresh", time.Now().Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	store.data[client.tokenKey()] = data
	_, err = client.AccessToken(context.Background())
	var status *HTTPError
	if !errors.As(err, &status) || status.StatusCode != 401 {
		t.Fatalf("status: %v", err)
	}
	if _, err := store.Get(client.tokenKey()); !errors.Is(err, ErrCredentialNotFound) {
		t.Fatalf("credential retained: %v", err)
	}
	if _, err := client.AccessToken(context.Background()); !errors.Is(err, ErrCredentialNotFound) {
		t.Fatalf("signed out state: %v", err)
	}
}

func TestSwiftDateAndRelayURL(t *testing.T) {
	var tokens Tokens
	if err := json.Unmarshal([]byte(`{"access_token":"a","refresh_token":"r","expires_at":0}`), &tokens); err != nil || !tokens.ExpiresAt.Equal(swiftEpoch) {
		t.Fatalf("Swift date: %+v %v", tokens, err)
	}
	for _, raw := range []string{"http://example.com", "https://user:pass@example.com", "file:///tmp/relay", "https://example.com/?x=1"} {
		if _, err := NewClient(raw, newMemoryStore(), nil); err == nil {
			t.Errorf("accepted %q", raw)
		}
	}
	for _, raw := range []string{"https://example.com", "http://localhost:3000", "http://127.0.0.1", "http://[::1]"} {
		if _, err := NewClient(raw, newMemoryStore(), nil); err != nil {
			t.Errorf("rejected %q: %v", raw, err)
		}
	}
}

func TestPKCEExchange(t *testing.T) {
	var challenge string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/auth/exchange" || r.Method != http.MethodPost {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(404)
			return
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		digest := sha256.Sum256([]byte(body["verifier"]))
		if body["code"] != "grant" || body["id"] != "00112233-4455-6677-8899-aabbccddeeff" || base64.RawURLEncoding.EncodeToString(digest[:]) != challenge || body["agreement_key"] == "" || body["signing_key"] == "" {
			t.Errorf("invalid exchange request: %+v", body)
		}
		json.NewEncoder(w).Encode(map[string]string{"access_token": "a", "refresh_token": "r", "expires_at": "2030-01-02T03:04:05.123Z"})
	}))
	defer server.Close()
	store := newMemoryStore()
	client, err := NewClient(server.URL, store, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	start, verifier, err := client.BeginSignIn()
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(start)
	if err != nil {
		t.Fatal(err)
	}
	challenge = u.Query().Get("code_challenge")
	if u.Path != "/v1/auth/google/start" || u.Query().Get("callback") != "kero://remote-auth" || len(verifier) != 43 {
		t.Fatalf("invalid start URL: %s", start)
	}
	identity := vectorIdentity(t, "00112233-4455-6677-8899-aabbccddeeff", "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	tokens, err := client.Exchange(context.Background(), "kero://remote-auth?code=grant", verifier, identity)
	if err != nil {
		t.Fatal(err)
	}
	if tokens.RefreshToken != "r" {
		t.Fatalf("tokens: %+v", tokens)
	}
	if _, err := store.Get(client.tokenKey()); err != nil {
		t.Fatal(err)
	}
}
