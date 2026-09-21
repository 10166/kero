//! Native SSH uses the pinned tty7 engine for key/agent/interactive auth,
//! host-key decisions and jump hosts. Only explicit group expansion should
//! call connect; this module deliberately has no reconnect loop.
use crate::protocol::VERSION;
use russh::{Channel, ChannelMsg, client::Msg};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use std::time::Duration;
use tty7_core::daemon::protocol::NativeSshSpec;
use tty7_core::daemon::ssh::{PromptBroker, SshConnection, SshManager};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    MacArm64,
    MacX86_64,
    LinuxArm64,
    LinuxX86_64,
}
impl Platform {
    pub fn parse(uname: &str) -> anyhow::Result<Self> {
        match uname.trim() {
            "Darwin arm64" | "Darwin aarch64" => Ok(Self::MacArm64),
            "Darwin x86_64" => Ok(Self::MacX86_64),
            "Linux aarch64" | "Linux arm64" => Ok(Self::LinuxArm64),
            "Linux x86_64" => Ok(Self::LinuxX86_64),
            _ => anyhow::bail!("unsupported SSH server platform: {}", uname.trim()),
        }
    }
    pub fn asset_name(self) -> &'static str {
        match self {
            Self::MacArm64 => "kero-daemon-aarch64-apple-darwin",
            Self::MacX86_64 => "kero-daemon-x86_64-apple-darwin",
            Self::LinuxArm64 => "kero-daemon-aarch64-unknown-linux-musl",
            Self::LinuxX86_64 => "kero-daemon-x86_64-unknown-linux-musl",
        }
    }
}

fn validate_algorithms(a: &tty7_core::daemon::protocol::SshAlgorithms) -> anyhow::Result<()> {
    for (name, empty, supported) in [
        (
            "KexAlgorithms",
            a.kex.is_empty(),
            a.kex
                .iter()
                .any(|s| russh::kex::Name::try_from(s.as_str()).is_ok()),
        ),
        (
            "Ciphers",
            a.cipher.is_empty(),
            a.cipher
                .iter()
                .any(|s| russh::cipher::Name::try_from(s.as_str()).is_ok()),
        ),
        (
            "MACs",
            a.mac.is_empty(),
            a.mac
                .iter()
                .any(|s| russh::mac::Name::try_from(s.as_str()).is_ok()),
        ),
        (
            "HostKeyAlgorithms",
            a.host_key.is_empty(),
            a.host_key
                .iter()
                .any(|s| s.parse::<russh::keys::Algorithm>().is_ok()),
        ),
        (
            "Compression",
            a.compression.is_empty(),
            a.compression
                .iter()
                .any(|s| russh::compression::Name::try_from(s.as_str()).is_ok()),
        ),
    ] {
        anyhow::ensure!(
            empty || supported,
            "Unsupported SSH {name}: no configured algorithm is supported"
        );
    }
    Ok(())
}

#[cfg(test)]
mod algorithm_tests {
    use super::*;
    use tty7_core::daemon::protocol::SshAlgorithms;
    #[test]
    fn ordered_allow_list_never_falls_back_to_unconfigured_algorithms() {
        let mut algorithms = SshAlgorithms::default();
        algorithms.kex = vec!["unsupported-kex".into()];
        assert!(validate_algorithms(&algorithms).is_err());
        algorithms.kex.push("curve25519-sha256".into());
        assert!(validate_algorithms(&algorithms).is_ok());
        algorithms.cipher = vec!["unsupported-cipher".into()];
        assert!(validate_algorithms(&algorithms).is_err());
    }
}

pub struct NativeConnection {
    connection: Arc<SshConnection>,
}
impl NativeConnection {
    pub async fn connect(spec: &NativeSshSpec, broker: &Arc<PromptBroker>) -> anyhow::Result<Self> {
        let mut hop = Some(spec);
        while let Some(spec) = hop {
            anyhow::ensure!(
                spec.verify_host_keys,
                "Kero requires host-key verification on every SSH hop"
            );
            // Configuration is an ordered allow-list. Negotiate the supported
            // intersection, never fall back to defaults when it is empty. This
            // also supports OpenSSH's ^preferred-algorithm plus default lists.
            validate_algorithms(&spec.algorithms)?;
            hop = spec.jump.as_deref();
        }
        let (connection, _) = SshManager::global().open_connection(spec, broker).await?;
        Ok(Self { connection })
    }
    pub async fn disconnect(&self) {
        self.connection.disconnect().await;
    }

    pub async fn command(&self, command: &str, input: &[u8]) -> anyhow::Result<Vec<u8>> {
        let mut channel = self.connection.open_command_channel().await?;
        channel.exec(true, command).await?;
        // The caller passes a bounded binary asset; russh applies channel
        // window backpressure during the upload, outside the UI thread.
        if !input.is_empty() {
            channel.data(input).await?;
        }
        channel.eof().await?;
        let result = tokio::time::timeout(Duration::from_secs(60), async {
            let mut output = Vec::new();
            let mut error_output = Vec::new();
            let mut status = None;
            while let Some(message) = channel.wait().await {
                match message {
                    ChannelMsg::Data { data } => {
                        output.extend_from_slice(&data);
                    }
                    ChannelMsg::ExtendedData { data, .. } => {
                        error_output.extend_from_slice(&data);
                    }
                    ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
                    ChannelMsg::Close => break,
                    _ => {}
                }
                anyhow::ensure!(
                    output.len() + error_output.len() <= 1024 * 1024,
                    "SSH command response too large"
                );
            }
            anyhow::ensure!(
                status == Some(0),
                "SSH command failed ({status:?}): {}",
                String::from_utf8_lossy(&error_output)
            );
            Ok(output)
        })
        .await;
        // Never replay a command after an uncertain transport outcome.
        result.map_err(|_| {
            anyhow::anyhow!("SSH command timed out; result unknown, do not automatically retry")
        })?
    }

    pub async fn platform(&self) -> anyhow::Result<Platform> {
        Platform::parse(std::str::from_utf8(&self.command("uname -sm", &[]).await?)?)
    }

    /// Install a bundled artifact only after its trusted manifest digest and
    /// remote platform match. Content-addressed paths leave running binaries
    /// intact; no service restart or in-place overwrite is permitted.
    pub async fn install(
        &self,
        platform: Platform,
        binary: &[u8],
        expected_sha256: &str,
    ) -> anyhow::Result<String> {
        self.install_with_progress(platform, binary, expected_sha256, || {})
            .await
    }

    pub async fn install_with_progress(
        &self,
        platform: Platform,
        binary: &[u8],
        expected_sha256: &str,
        mut uploading: impl FnMut(),
    ) -> anyhow::Result<String> {
        anyhow::ensure!(binary.len() <= 256 * 1024 * 1024, "daemon asset too large");
        let hash: String = Sha256::digest(binary)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        anyhow::ensure!(hash == expected_sha256, "bundled daemon checksum mismatch");
        anyhow::ensure!(
            self.platform().await? == platform,
            "daemon asset platform mismatch"
        );
        let home = self.command("printf '%s' \"$HOME\"", &[]).await?;
        let home = std::str::from_utf8(&home)?;
        anyhow::ensure!(
            home.starts_with('/') && !home.contains('\n'),
            "invalid remote home directory"
        );
        let directory = format!("{home}/.local/share/kero/daemon/{hash}");
        let path = format!("{directory}/kero-daemon");
        let temporary = format!("{directory}/upload-{}", uuid::Uuid::new_v4());
        let check = match platform {
            Platform::MacArm64 | Platform::MacX86_64 => "shasum -a 256",
            _ => "sha256sum",
        };
        // Content addressing makes reconnect read-only. Verify the existing
        // executable before deciding to upload; never replace a live binary.
        let cached = self.command(&format!(
            "set -eu; if [ -e {path} ]; then actual=$({check} {path}); [ \"${{actual%% *}}\" = {hash} ]; {path} --protocol; else printf missing; fi",
            path = quote(&path), hash = quote(&hash),
        ), &[]).await?;
        if cached != b"missing" {
            let protocol: serde_json::Value = serde_json::from_slice(&cached)?;
            anyhow::ensure!(
                protocol["product"] == "kero-daemon" && protocol["protocol"] == VERSION,
                "installed daemon protocol mismatch"
            );
            return Ok(path);
        }
        uploading();
        // `ln` publishes without replacing an existing executable. A failed
        // upload is removed by the shell trap, including checksum failures.
        let script = format!(
            "set -eu; umask 077; mkdir -p {dir}; trap {cleanup} EXIT HUP INT TERM; cat > {tmp}; actual=$({check} {tmp}); [ \"${{actual%% *}}\" = {hash} ]; chmod 700 {tmp}; if [ -e {path} ]; then actual=$({check} {path}); [ \"${{actual%% *}}\" = {hash} ]; else ln {tmp} {path}; fi; {path} --protocol",
            dir = quote(&directory),
            tmp = quote(&temporary),
            path = quote(&path),
            hash = quote(&hash),
            cleanup = quote(&format!("rm -f {}", quote(&temporary))),
        );
        let protocol = self.command(&script, binary).await?;
        let protocol: serde_json::Value = serde_json::from_slice(&protocol)?;
        anyhow::ensure!(
            protocol["product"] == "kero-daemon" && protocol["protocol"] == VERSION,
            "installed daemon protocol mismatch"
        );
        Ok(path)
    }

    pub async fn start(&self, binary: &str, state_directory: &str) -> anyhow::Result<()> {
        anyhow::ensure!(
            state_directory.starts_with('/'),
            "remote state directory must be absolute"
        );
        // Probe first rather than spawning a losing --serve process on every
        // reconnect. --ensure also handles startup races through the lock.
        let script = format!(
            "{binary} --ensure --state-dir {state}",
            state = quote(state_directory),
            binary = quote(binary),
        );
        self.command(&script, &[]).await?;
        Ok(())
    }

    pub async fn bridge(
        &self,
        binary: &str,
        state_directory: &str,
    ) -> anyhow::Result<Channel<Msg>> {
        let channel = self.connection.open_session_channel().await?;
        // The SSH transport can outlive its daemon. A fresh channel must
        // recover that service before attaching, without recreating a PTY or
        // replaying an uncertain file/Git request. --ensure preserves an
        // already running daemon through its probe and lifetime lock.
        channel
            .exec(
                true,
                format!(
                    "{binary} --ensure --state-dir {state} >/dev/null && exec {binary} --stdio --state-dir {state}",
                    binary = quote(binary),
                    state = quote(state_directory)
                ),
            )
            .await?;
        Ok(channel)
    }
}

fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn platforms_are_explicit_and_shell_arguments_remain_literal() {
        for (name, platform) in [
            ("Darwin arm64", Platform::MacArm64),
            ("Darwin x86_64", Platform::MacX86_64),
            ("Linux aarch64", Platform::LinuxArm64),
            ("Linux x86_64", Platform::LinuxX86_64),
        ] {
            assert_eq!(Platform::parse(name).unwrap(), platform);
            assert!(platform.asset_name().starts_with("kero-daemon-"));
        }
        assert!(Platform::parse("Linux riscv64").is_err());
        assert_eq!(quote("a'b$(id)"), "'a'\\''b$(id)'");
    }
}
