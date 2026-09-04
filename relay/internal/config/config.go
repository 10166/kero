package config

import (
	"errors"
	"net/url"
	"os"
)

type Config struct {
	ListenAddr         string
	BaseURL            string
	DatabasePath       string
	GoogleClientID     string
	GoogleClientSecret string
	TokenSecret        string
}

func Load() (Config, error) {
	c := Config{
		ListenAddr:         value("KERO_LISTEN_ADDR", ":8080"),
		BaseURL:            os.Getenv("KERO_RELAY_BASE_URL"),
		DatabasePath:       value("KERO_DATABASE_PATH", "/data/kero-relay.db"),
		GoogleClientID:     os.Getenv("KERO_GOOGLE_CLIENT_ID"),
		GoogleClientSecret: os.Getenv("KERO_GOOGLE_CLIENT_SECRET"),
		TokenSecret:        os.Getenv("KERO_TOKEN_SECRET"),
	}
	if c.BaseURL == "" || c.GoogleClientID == "" || c.GoogleClientSecret == "" {
		return Config{}, errors.New("KERO_RELAY_BASE_URL and Google OAuth credentials are required")
	}
	baseURL, err := url.Parse(c.BaseURL)
	loopback := baseURL != nil && (baseURL.Hostname() == "localhost" || baseURL.Hostname() == "127.0.0.1" || baseURL.Hostname() == "::1")
	if err != nil || baseURL.Host == "" || (baseURL.Scheme != "https" && !(baseURL.Scheme == "http" && loopback)) {
		return Config{}, errors.New("KERO_RELAY_BASE_URL must use HTTPS, except for loopback development")
	}
	if len(c.TokenSecret) < 32 {
		return Config{}, errors.New("KERO_TOKEN_SECRET must contain at least 32 bytes")
	}
	return c, nil
}

func value(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
