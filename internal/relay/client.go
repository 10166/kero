package relay

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// HTTPError reports a non-success relay response.
type HTTPError struct{ StatusCode int }

func (e *HTTPError) Error() string { return fmt.Sprintf("relay: HTTP status %d", e.StatusCode) }

// Tokens uses the Swift keychain JSON representation, including Date's
// numeric seconds since 2001, and accepts the server's RFC3339 timestamps.
type Tokens struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	ExpiresAt    time.Time `json:"-"`
}

var swiftEpoch = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)

func (t Tokens) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Access  string  `json:"access_token"`
		Refresh string  `json:"refresh_token"`
		Expiry  float64 `json:"expires_at"`
	}{t.AccessToken, t.RefreshToken, t.ExpiresAt.Sub(swiftEpoch).Seconds()})
}
func (t *Tokens) UnmarshalJSON(data []byte) error {
	var v struct {
		Access  string          `json:"access_token"`
		Refresh string          `json:"refresh_token"`
		Expiry  json.RawMessage `json:"expires_at"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	var expiry time.Time
	var raw string
	if json.Unmarshal(v.Expiry, &raw) == nil {
		var err error
		expiry, err = time.Parse(time.RFC3339Nano, raw)
		if err != nil {
			return fmt.Errorf("relay: invalid token expiry: %w", err)
		}
	} else {
		var seconds float64
		if err := json.Unmarshal(v.Expiry, &seconds); err != nil || len(v.Expiry) == 0 || string(v.Expiry) == "null" {
			return errors.New("relay: invalid token expiry")
		}
		whole := int64(seconds)
		expiry = swiftEpoch.Add(time.Duration(whole)*time.Second + time.Duration((seconds-float64(whole))*float64(time.Second)))
	}
	if v.Access == "" || v.Refresh == "" {
		return errors.New("relay: missing token")
	}
	*t = Tokens{v.Access, v.Refresh, expiry}
	return nil
}

// Client handles relay credentials and HTTP operations. Concurrent callers
// share a single refresh, because refresh tokens are consumed on use.
type Client struct {
	base   *url.URL
	store  CredentialStore
	http   *http.Client
	mu     sync.Mutex
	tokens *Tokens
	loaded bool
	dirty  bool
}

// NewClient permits HTTPS or HTTP to localhost, 127.0.0.1, or ::1.
func NewClient(rawURL string, store CredentialStore, httpClient *http.Client) (*Client, error) {
	u, err := url.Parse(rawURL)
	if err != nil || u == nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" {
		return nil, errors.New("relay: invalid URL")
	}
	host := strings.ToLower(u.Hostname())
	if u.Scheme != "https" && !(u.Scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")) {
		return nil, errors.New("relay: URL must use HTTPS or loopback HTTP")
	}
	if store == nil {
		return nil, errors.New("relay: credential store is required")
	}
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	// Never forward bearer credentials to another origin through redirects.
	copyClient := *httpClient
	previousRedirect := copyClient.CheckRedirect
	copyClient.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) >= 10 || !strings.EqualFold(req.URL.Host, u.Host) || !strings.EqualFold(req.URL.Scheme, u.Scheme) {
			return errors.New("relay: unsafe redirect")
		}
		if previousRedirect != nil {
			return previousRedirect(req, via)
		}
		return nil
	}
	return &Client{base: u, store: store, http: &copyClient}, nil
}
func (c *Client) endpoint(path string) *url.URL {
	u := *c.base
	u.Path = strings.TrimRight(u.Path, "/") + "/" + path
	u.RawPath = ""
	return &u
}
func (c *Client) tokenKey() string { return "tokens:" + c.base.String() }

// BeginSignIn returns the browser URL and its PKCE verifier, which must be
// retained until Exchange receives the kero://remote-auth callback.
func (c *Client) BeginSignIn() (string, string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", "", err
	}
	verifier := base64.RawURLEncoding.EncodeToString(b[:])
	challenge := sha256.Sum256([]byte(verifier))
	u := c.endpoint("v1/auth/google/start")
	q := u.Query()
	q.Set("code_challenge", base64.RawURLEncoding.EncodeToString(challenge[:]))
	q.Set("callback", "kero://remote-auth")
	u.RawQuery = q.Encode()
	return u.String(), verifier, nil
}

func (c *Client) request(ctx context.Context, method, path, token string, body any, out any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = strings.NewReader(string(data))
	}
	req, err := http.NewRequestWithContext(ctx, method, c.endpoint(path).String(), reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return &HTTPError{response.StatusCode}
	}
	if out != nil {
		if err := json.NewDecoder(io.LimitReader(response.Body, 2<<20)).Decode(out); err != nil {
			return fmt.Errorf("relay: decode response: %w", err)
		}
	}
	return nil
}

// Exchange consumes the callback code, then stores the issued credentials.
func (c *Client) Exchange(ctx context.Context, callbackURL, verifier string, identity *Identity) (Tokens, error) {
	var t Tokens
	if identity == nil || identity.agreement == nil || len(identity.signing) == 0 {
		return t, errors.New("relay: missing identity")
	}
	u, err := url.Parse(callbackURL)
	if err != nil || u.Scheme != "kero" || u.Host != "remote-auth" || u.Path != "" || u.User != nil || u.Fragment != "" {
		return t, errors.New("relay: invalid authentication callback")
	}
	codes := u.Query()["code"]
	if len(codes) != 1 || codes[0] == "" || verifier == "" {
		return t, errors.New("relay: missing authentication code or verifier")
	}
	record := identity.Record()
	body := map[string]string{"code": codes[0], "verifier": verifier, "id": record.ID, "agreement_key": record.AgreementKey, "signing_key": record.SigningKey}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.request(ctx, http.MethodPost, "v1/auth/exchange", "", body, &t); err != nil {
		return Tokens{}, err
	}
	c.tokens = &t
	c.loaded = true
	c.dirty = true
	if err := c.persistLocked(); err != nil {
		return t, err
	}
	return t, nil
}
func (c *Client) loadLocked() error {
	if c.loaded {
		if c.tokens == nil {
			return ErrCredentialNotFound
		}
		return nil
	}
	data, err := c.store.Get(c.tokenKey())
	if err != nil {
		return err
	}
	var t Tokens
	if err := json.Unmarshal(data, &t); err != nil {
		return fmt.Errorf("relay: decode stored tokens: %w", err)
	}
	c.tokens = &t
	c.loaded = true
	return nil
}
func (c *Client) persistLocked() error {
	data, err := json.Marshal(c.tokens)
	if err == nil {
		err = c.store.Set(c.tokenKey(), data)
	}
	if err != nil {
		return fmt.Errorf("relay: storing rotated credentials: %w", err)
	}
	c.dirty = false
	return nil
}
func (c *Client) Tokens() (Tokens, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.loadLocked(); err != nil {
		return Tokens{}, err
	}
	return *c.tokens, nil
}
func (c *Client) AccessToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.loadLocked(); err != nil {
		return "", err
	}
	if c.dirty {
		if err := c.persistLocked(); err != nil {
			return "", err
		}
	}
	if time.Until(c.tokens.ExpiresAt) < time.Minute {
		var rotated Tokens
		err := c.request(ctx, http.MethodPost, "v1/auth/refresh", "", map[string]string{"refresh_token": c.tokens.RefreshToken}, &rotated)
		if err != nil {
			var status *HTTPError
			if errors.As(err, &status) && status.StatusCode == http.StatusUnauthorized {
				c.tokens = nil
				c.loaded = true
				c.dirty = false
				if deleteErr := c.store.Delete(c.tokenKey()); deleteErr != nil && !errors.Is(deleteErr, ErrCredentialNotFound) {
					return "", errors.Join(err, fmt.Errorf("relay: removing invalid credentials: %w", deleteErr))
				}
			}
			return "", err
		}
		c.tokens = &rotated
		c.dirty = true
		if err := c.persistLocked(); err != nil {
			return "", err
		}
	}
	return c.tokens.AccessToken, nil
}
func (c *Client) SignOut() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.tokens = nil
	c.loaded = true
	c.dirty = false
	err := c.store.Delete(c.tokenKey())
	if errors.Is(err, ErrCredentialNotFound) {
		return nil
	}
	return err
}
func (c *Client) Register(ctx context.Context, identity *Identity) error {
	if identity == nil || identity.agreement == nil || len(identity.signing) == 0 {
		return errors.New("relay: missing identity")
	}
	token, err := c.AccessToken(ctx)
	if err != nil {
		return err
	}
	return c.request(ctx, http.MethodPost, "v1/devices", token, identity.Record(), nil)
}
func (c *Client) Devices(ctx context.Context) ([]Device, error) {
	token, err := c.AccessToken(ctx)
	if err != nil {
		return nil, err
	}
	var result struct {
		Devices []Device `json:"devices"`
	}
	if err := c.request(ctx, http.MethodGet, "v1/devices", token, nil, &result); err != nil {
		return nil, err
	}
	return result.Devices, nil
}
func (c *Client) Revoke(ctx context.Context, deviceID string) error {
	id, err := normalizeUUID(deviceID)
	if err != nil {
		return err
	}
	token, err := c.AccessToken(ctx)
	if err != nil {
		return err
	}
	return c.request(ctx, http.MethodDelete, "v1/devices/"+id, token, nil, nil)
}
