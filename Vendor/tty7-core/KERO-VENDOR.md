# tty7-core provenance

Source: https://github.com/l0ng-ai/tty7/tree/ffce219ffaff0e01c00811b9ebc78c25a827b2b3/crates/tty7-core
Revision: `ffce219ffaff0e01c00811b9ebc78c25a827b2b3`
License: Apache-2.0; the upstream license is retained in LICENSE.
Copyright and attribution: tty7 contributors. No upstream NOTICE was present.

Only the framework-free core is vendored; no gpui or tty7 workspace UI is included.
Kero changes: expand inherited Cargo workspace metadata/dependencies/lints so this
crate can build independently. Expose `SshManager::open_connection` and add `SshConnection::disconnect` so Kero
can use authenticated channels without the tty7 installer and close a collapsed group. Kero supplies
its own configuration directory and does not start the upstream daemon or installer.
The consuming daemon pins the upstream russh patch revision too.
