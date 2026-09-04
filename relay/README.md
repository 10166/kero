# Kero relay

The relay authenticates Kero devices, reports account-scoped presence, and
forwards end-to-end encrypted frames. It never receives terminal plaintext.

## Run

Create a Google OAuth web application whose callback URL is
`https://your-relay.example/v1/auth/google/callback`, then run:

```bash
docker compose up --build
```

The Compose port binds to loopback. Put a TLS reverse proxy in front of it and
set `KERO_RELAY_BASE_URL` to that public HTTPS origin. The relay and Kero accept
plain HTTP only for loopback development URLs.

Required environment variables:

- `KERO_RELAY_BASE_URL`
- `KERO_GOOGLE_CLIENT_ID`
- `KERO_GOOGLE_CLIENT_SECRET`
- `KERO_TOKEN_SECRET` (at least 32 random bytes)

Optional: `KERO_LISTEN_ADDR` (default `:8080`) and `KERO_DATABASE_PATH`
(default `/data/kero-relay.db`). Every valid Google account can create an
account, and account IDs are derived from Google's issuer and subject so one
account can never enumerate or route to another account's devices. Access and
refresh tokens are bound to the enrolled device; revoking a device immediately
disconnects it and invalidates both kinds of token.

The relay can observe account/device metadata, connection timing, routing IDs,
and ciphertext sizes. Topology, terminal output, input, and resize payloads are
encrypted between Kero devices and are never available to the relay as
plaintext. See the repository `SECURITY.md` for the complete trust boundary.
