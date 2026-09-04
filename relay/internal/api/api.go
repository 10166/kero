package api

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/egoist/kero/relay/internal/config"
	"github.com/egoist/kero/relay/internal/hub"
	"github.com/egoist/kero/relay/internal/store"
	"golang.org/x/oauth2"
)

type API struct {
	cfg      config.Config
	store    *store.Store
	oauth    oauth2.Config
	verifier *oidc.IDTokenVerifier
	hub      *hub.Hub
}

func New(ctx context.Context, cfg config.Config, st *store.Store) (*API, error) {
	provider, err := oidc.NewProvider(ctx, "https://accounts.google.com")
	if err != nil {
		return nil, err
	}
	a := &API{cfg: cfg, store: st, verifier: provider.Verifier(&oidc.Config{ClientID: cfg.GoogleClientID})}
	a.oauth = oauth2.Config{ClientID: cfg.GoogleClientID, ClientSecret: cfg.GoogleClientSecret, Endpoint: provider.Endpoint(), RedirectURL: strings.TrimRight(cfg.BaseURL, "/") + "/v1/auth/google/callback", Scopes: []string{oidc.ScopeOpenID, "email"}}
	a.hub = hub.New(st.DeviceBelongsTo)
	return a, nil
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("GET /v1/auth/google/start", a.startGoogle)
	mux.HandleFunc("GET /v1/auth/google/callback", a.finishGoogle)
	mux.HandleFunc("POST /v1/auth/exchange", a.exchange)
	mux.HandleFunc("POST /v1/auth/refresh", a.refresh)
	mux.HandleFunc("GET /v1/devices", a.withAccount(a.devices))
	mux.HandleFunc("POST /v1/devices", a.withAccount(a.registerDevice))
	mux.HandleFunc("DELETE /v1/devices/{id}", a.withAccount(a.revokeDevice))
	mux.HandleFunc("GET /v1/socket", a.socket)
	return securityHeaders(requestLog(mux))
}

type authState struct {
	State, Challenge, Callback, Verifier string
	Expires                              int64
}

func (a *API) startGoogle(w http.ResponseWriter, r *http.Request) {
	challenge := r.URL.Query().Get("code_challenge")
	callback := r.URL.Query().Get("callback")
	if len(challenge) < 43 || len(challenge) > 128 || callback != "kero://remote-auth" {
		http.Error(w, "invalid OAuth parameters", 400)
		return
	}
	state := randomToken(24)
	verifier := randomToken(32)
	payload, _ := json.Marshal(authState{state, challenge, callback, verifier, time.Now().Add(10 * time.Minute).Unix()})
	sealed := sealState(payload, []byte(a.cfg.TokenSecret))
	http.SetCookie(w, &http.Cookie{Name: "kero_oauth", Value: sealed, Path: "/v1/auth/google", HttpOnly: true, Secure: strings.HasPrefix(a.cfg.BaseURL, "https://"), SameSite: http.SameSiteLaxMode, MaxAge: 600})
	params := []oauth2.AuthCodeOption{oauth2.AccessTypeOffline, oidc.Nonce(state), oauth2.SetAuthURLParam("code_challenge", pkce(verifier)), oauth2.SetAuthURLParam("code_challenge_method", "S256")}
	http.Redirect(w, r, a.oauth.AuthCodeURL(state, params...), http.StatusFound)
}

func (a *API) finishGoogle(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("kero_oauth")
	if err != nil {
		http.Error(w, "missing OAuth state", 400)
		return
	}
	payload, ok := openState(cookie.Value, []byte(a.cfg.TokenSecret))
	if !ok {
		http.Error(w, "invalid OAuth state", 400)
		return
	}
	var state authState
	if json.Unmarshal(payload, &state) != nil || state.State != r.URL.Query().Get("state") || time.Now().Unix() > state.Expires {
		http.Error(w, "expired OAuth state", 400)
		return
	}
	token, err := a.oauth.Exchange(r.Context(), r.URL.Query().Get("code"), oauth2.SetAuthURLParam("code_verifier", state.Verifier))
	if err != nil {
		http.Error(w, "Google exchange failed", 401)
		return
	}
	raw, _ := token.Extra("id_token").(string)
	idToken, err := a.verifier.Verify(r.Context(), raw)
	if err != nil {
		http.Error(w, "invalid Google identity", 401)
		return
	}
	var claims struct {
		Subject string `json:"sub"`
		Issuer  string `json:"iss"`
		Nonce   string `json:"nonce"`
	}
	if idToken.Claims(&claims) != nil || claims.Subject == "" || subtle.ConstantTimeCompare([]byte(claims.Nonce), []byte(state.State)) != 1 {
		http.Error(w, "invalid Google claims", 401)
		return
	}
	accountID := store.AccountID(claims.Issuer, claims.Subject)
	if a.store.EnsureAccount(r.Context(), accountID) != nil {
		http.Error(w, "account error", 500)
		return
	}
	grant := randomToken(32)
	if a.store.PutLoginGrant(r.Context(), store.HashToken(grant), accountID, state.Challenge, state.Callback, time.Now().Add(2*time.Minute)) != nil {
		http.Error(w, "grant error", 500)
		return
	}
	destination, _ := url.Parse(state.Callback)
	q := destination.Query()
	q.Set("code", grant)
	destination.RawQuery = q.Encode()
	http.Redirect(w, r, destination.String(), http.StatusFound)
}

func (a *API) exchange(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code         string `json:"code"`
		Verifier     string `json:"verifier"`
		ID           string `json:"id"`
		AgreementKey string `json:"agreement_key"`
		SigningKey   string `json:"signing_key"`
	}
	if !decodeJSON(w, r, &body) {
		return
	}
	if !validUUID(body.ID) || !validDeviceKey(body.AgreementKey) || !validDeviceKey(body.SigningKey) {
		http.Error(w, "invalid device", 400)
		return
	}
	accountID, challenge, err := a.store.ConsumeLoginGrant(r.Context(), store.HashToken(body.Code))
	if err != nil || subtle.ConstantTimeCompare([]byte(challenge), []byte(pkce(body.Verifier))) != 1 {
		http.Error(w, "invalid grant", 401)
		return
	}
	if a.store.EnrollDevice(r.Context(), accountID, store.Device{ID: body.ID, AgreementKey: body.AgreementKey, SigningKey: body.SigningKey}) != nil {
		http.Error(w, "device error", 500)
		return
	}
	a.issueTokens(w, r, accountID, body.ID)
}

func (a *API) refresh(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RefreshToken string `json:"refresh_token"`
	}
	if !decodeJSON(w, r, &body) {
		return
	}
	accountID, deviceID, err := a.store.ConsumeRefresh(r.Context(), body.RefreshToken)
	if err != nil {
		http.Error(w, "invalid refresh token", 401)
		return
	}
	a.issueTokens(w, r, accountID, deviceID)
}

func (a *API) issueTokens(w http.ResponseWriter, r *http.Request, accountID, deviceID string) {
	access, refresh := randomToken(32), randomToken(48)
	accessExpiry := time.Now().Add(15 * time.Minute)
	refreshExpiry := time.Now().Add(30 * 24 * time.Hour)
	if a.store.PutSession(r.Context(), access, accountID, deviceID, "access", accessExpiry) != nil || a.store.PutSession(r.Context(), refresh, accountID, deviceID, "refresh", refreshExpiry) != nil {
		http.Error(w, "session error", 500)
		return
	}
	writeJSON(w, map[string]any{"access_token": access, "refresh_token": refresh, "expires_at": accessExpiry.UTC().Format(time.RFC3339Nano)})
}

func (a *API) withAccount(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		account, _, err := a.authenticate(r)
		if err != nil {
			http.Error(w, "unauthorized", 401)
			return
		}
		next(w, r, account)
	}
}

func (a *API) authenticate(r *http.Request) (string, string, error) {
	value := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if value == "" {
		return "", "", errors.New("missing bearer")
	}
	return a.store.Authenticate(r.Context(), value)
}

func (a *API) devices(w http.ResponseWriter, r *http.Request, account string) {
	devices, err := a.store.Devices(r.Context(), account)
	if err != nil {
		http.Error(w, "device error", 500)
		return
	}
	writeJSON(w, map[string]any{"devices": devices})
}
func (a *API) registerDevice(w http.ResponseWriter, r *http.Request, account string) {
	var d store.Device
	if !decodeJSON(w, r, &d) {
		return
	}
	_, deviceID, err := a.authenticate(r)
	if err != nil || !strings.EqualFold(d.ID, deviceID) || !validUUID(d.ID) || !validDeviceKey(d.AgreementKey) || !validDeviceKey(d.SigningKey) {
		http.Error(w, "invalid device", 400)
		return
	}
	d.ID = strings.ToLower(d.ID)
	if a.store.UpdateDevice(r.Context(), account, d) != nil {
		http.Error(w, "device error", 500)
		return
	}
	w.WriteHeader(204)
}
func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request, account string) {
	id := r.PathValue("id")
	if !validUUID(id) {
		http.Error(w, "invalid device", 400)
		return
	}
	if a.store.RevokeDevice(r.Context(), account, id) != nil {
		http.Error(w, "device error", 500)
		return
	}
	a.hub.Disconnect(account, id)
	w.WriteHeader(204)
}

func (a *API) socket(w http.ResponseWriter, r *http.Request) {
	account, authorizedDeviceID, err := a.authenticate(r)
	deviceID := r.URL.Query().Get("device_id")
	if err != nil || !validUUID(deviceID) || deviceID != authorizedDeviceID || !a.store.DeviceBelongsTo(r.Context(), account, deviceID) {
		http.Error(w, "unauthorized", 401)
		return
	}
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{OriginPatterns: []string{"*"}, CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	defer conn.CloseNow()
	conn.SetReadLimit(hub.MaxFrameBytes)
	_ = a.store.TouchDevice(r.Context(), account, deviceID)
	if err := a.hub.Run(r.Context(), &hub.Peer{AccountID: account, DeviceID: deviceID, Conn: conn, Send: make(chan hub.Outbound, 256)}); err != nil {
		slog.Debug("socket closed", "device", deviceID, "error", err)
	}
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if dec.Decode(dst) != nil {
		http.Error(w, "invalid JSON", 400)
		return false
	}
	return true
}
func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
func randomToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func pkce(v string) string {
	h := sha256.Sum256([]byte(v))
	return base64.RawURLEncoding.EncodeToString(h[:])
}
func validUUID(v string) bool {
	if len(v) != 36 {
		return false
	}
	for i, c := range v {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			return false
		}
	}
	return true
}
func validDeviceKey(v string) bool {
	b, err := base64.StdEncoding.DecodeString(v)
	return err == nil && len(b) == 32
}

// OAuth state only protects short-lived browser correlation. Terminal and
// topology payloads use device-to-device encryption in the Kero clients.
func sealState(p, key []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write(p)
	sum := mac.Sum(nil)
	return base64.RawURLEncoding.EncodeToString(append(sum, p...))
}
func openState(v string, key []byte) ([]byte, bool) {
	b, err := base64.RawURLEncoding.DecodeString(v)
	if err != nil || len(b) < 32 {
		return nil, false
	}
	p := b[32:]
	mac := hmac.New(sha256.New, key)
	mac.Write(p)
	return p, hmac.Equal(b[:32], mac.Sum(nil))
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}
func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		slog.Info("request", "method", r.Method, "path", r.URL.Path, "duration_ms", time.Since(start).Milliseconds())
	})
}
