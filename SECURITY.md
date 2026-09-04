# Security Policy

## Supported Versions

Only the latest release of Kero receives security fixes. Updates ship
through the in-app updater and https://kero.sh.

## Reporting a Vulnerability

Please use GitHub private vulnerability reporting:
https://github.com/egoist/kero/security/advisories/new

If that doesn't work for you, email hi@egoist.dev.

Please don't open a public issue for anything you believe is
exploitable before it has been fixed. Include reproduction steps and
the Kero version (Kero → About Kero) you tested.

## Scope

Kero embeds libghostty (vendored in `Vendor/libghostty-spm`) for
terminal emulation. In scope here: Kero's configuration and host
integration of it — clipboard access, escape-sequence handling that
crosses a trust boundary, the update chain, and anything that lets
terminal output reach data outside the session. Vulnerabilities in
upstream Ghostty itself should also be reported to the Ghostty
project: https://github.com/ghostty-org/ghostty/security.

## Remote control trust boundary

Remote control is disabled on each Mac until the user explicitly enables it.
Once enabled, any non-revoked Kero device enrolled through the same Google
account can see that Mac's Kero project/tab/pane topology and request exclusive
control of a terminal without another confirmation prompt. Only one remote
device can control a terminal at a time. The host stays visible and read-only,
and its **Take Back Control** button immediately revokes the controller and
restores local input and resize ownership.

Terminal output, input, resizes, and topology frames are encrypted between the
devices with Curve25519-derived ChaCha20-Poly1305 keys. Device private keys and
login tokens are stored in macOS Keychain. The relay authenticates Google
accounts, binds tokens to a device, enforces account-scoped routing, and stores
only public device keys; it cannot decrypt frame payloads. It can still observe
account/device metadata, online presence, routing identifiers, timing, and
ciphertext sizes.

Each socket connection uses a fresh device epoch, and terminal attachment is
bound to both peers' current epochs. Previously recorded attach frames therefore
cannot be replayed after either Kero reconnects. Long-lived device pair keys do
not provide forward secrecy, so the macOS Keychain material remains sensitive.

This design trusts the configured relay not to replace a device's public key
during enrollment or discovery; it does not provide key transparency or an
out-of-band key-verification ceremony. A compromised relay that substitutes
keys can therefore defeat the intended end-to-end confidentiality. Operators
must serve the relay over HTTPS, protect its Google OAuth credentials and token
secret, and keep its host updated. Remote renderers deny terminal-initiated
clipboard reads and writes and suppress desktop notifications and URL opens so
a hosted terminal cannot act through the controller's macOS integrations.
