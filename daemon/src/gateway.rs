//! One GUI host group owns one native SSH connection. Local socket clients
//! become independent SSH channels, all cancelled when the group closes stdin.
use crate::ssh::NativeConnection;
use serde::Deserialize;
use serde_json::json;
use std::{io::Write, path::PathBuf, sync::Arc};
use tokio::io::{AsyncBufReadExt, BufReader};
use tty7_core::daemon::{
    protocol::{AuthResponse, DaemonMsg, NativeSshSpec},
    ssh::PromptBroker,
};

#[derive(Deserialize)]
struct Configuration {
    spec: NativeSshSpec,
    assets: PathBuf,
    socket: PathBuf,
    namespace: String,
}
#[derive(Deserialize)]
struct Answer {
    request_id: u64,
    response: AuthResponse,
}
fn emit(value: serde_json::Value) -> bool {
    let mut out = std::io::stdout().lock();
    serde_json::to_writer(&mut out, &value).is_ok() && writeln!(out).is_ok() && out.flush().is_ok()
}
pub async fn run() -> anyhow::Result<()> {
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    let config: Configuration = serde_json::from_str(
        &input
            .next_line()
            .await?
            .ok_or_else(|| anyhow::anyhow!("missing SSH configuration"))?,
    )?;
    anyhow::ensure!(
        config.namespace.starts_with("kero")
            && config.namespace.len() <= 64
            && config
                .namespace
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-'),
        "invalid namespace"
    );
    anyhow::ensure!(
        config.socket.is_absolute(),
        "gateway socket must be absolute"
    );
    let parent = config
        .socket
        .parent()
        .ok_or_else(|| anyhow::anyhow!("socket parent missing"))?;
    let metadata = std::fs::symlink_metadata(parent)?;
    use std::os::unix::fs::MetadataExt;
    anyhow::ensure!(
        metadata.is_dir()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.mode() & 0o077 == 0,
        "gateway directory must be private"
    );
    // Never remove another gateway's live endpoint. Each generation has its
    // own random directory, owned and removed by the GUI after process exit.
    let listener = tokio::net::UnixListener::bind(&config.socket)?;
    let broker = PromptBroker::new(Box::new(|message| match message {
        DaemonMsg::AuthPrompt { request_id, prompt } => {
            emit(json!({"event":"auth","request_id":request_id,"prompt":prompt}))
        }
        DaemonMsg::SshStatus { phase } => emit(json!({"event":"ssh_status","phase":phase})),
        _ => true,
    }));
    let cancelled = Arc::new(tokio::sync::Notify::new());
    let cancel = cancelled.clone();
    let answers = broker.clone();
    tokio::spawn(async move {
        while let Ok(Some(line)) = input.next_line().await {
            if let Ok(answer) = serde_json::from_str::<Answer>(&line) {
                answers.deliver(answer.request_id, answer.response);
            }
        }
        cancel.notify_one();
    });
    let connected = async {
        let connection = Arc::new(NativeConnection::connect(&config.spec, &broker).await?);
        let platform = connection.platform().await?;
        emit(json!({"event":"checking","platform":platform.asset_name()}));
        let asset = config.assets.join(platform.asset_name());
        let manifest: serde_json::Value =
            serde_json::from_slice(&std::fs::read(asset.with_extension("json"))?)?;
        anyhow::ensure!(
            manifest["asset"] == platform.asset_name()
                && manifest["protocol"] == crate::protocol::VERSION,
            "invalid daemon manifest"
        );
        let binary = std::fs::read(&asset)?;
        let remote = connection
            .install_with_progress(
                platform,
                &binary,
                manifest["sha256"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("missing daemon digest"))?,
                || {
                    emit(json!({"event":"installing","platform":platform.asset_name()}));
                },
            )
            .await?;
        // The connection can live for days; the installer payload is no longer
        // needed once its immutable remote executable has been verified.
        drop(binary);
        let home = String::from_utf8(connection.command("printf '%s' \"$HOME\"", &[]).await?)?;
        let shell = String::from_utf8(
            connection
                .command("printf '%s' \"${SHELL:-/bin/sh}\"", &[])
                .await?,
        )?;
        anyhow::ensure!(
            home.starts_with('/') && shell.starts_with('/'),
            "invalid remote login environment"
        );
        let state = format!("{home}/.local/state/{}/daemon-v1", config.namespace);
        connection.start(&remote, &state).await?;
        emit(json!({"event":"ready","home":home,"shell":shell,"socket":config.socket}));
        let permits = Arc::new(tokio::sync::Semaphore::new(64));
        let mut tasks = tokio::task::JoinSet::new();
        loop {
            let (mut local, _) = listener.accept().await?;
            let permit = permits.clone().try_acquire_owned();
            let Ok(permit) = permit else {
                drop(local);
                continue;
            };
            let connection = connection.clone();
            let remote = remote.clone();
            let state = state.clone();
            tasks.spawn(async move {
                let _permit = permit;
                if let Ok(channel) = connection.bridge(&remote, &state).await {
                    let mut remote = channel.into_stream();
                    let _ = tokio::io::copy_bidirectional(&mut local, &mut remote).await;
                }
            });
            while tasks.try_join_next().is_some() {}
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let result = tokio::select! { result=connected => result, _=cancelled.notified()=>Ok(()) };
    let _ = std::fs::remove_file(&config.socket);
    if let Err(error) = &result {
        emit(json!({"event":"failed","message":error.to_string()}));
    }
    result
}
