//! Explicit opt-in fixture: no user's SSH keys, known_hosts, or system sshd
//! configuration are edited. See tests/run-daemon-ssh-checks.py.
use kero_daemon::{protocol::*, ssh::NativeConnection};
use std::sync::{Arc, OnceLock, Weak};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tty7_core::daemon::protocol::{AuthPromptKind, AuthResponse, DaemonMsg, NativeSshSpec};
use tty7_core::daemon::ssh::PromptBroker;

fn broker(fingerprint: String) -> Arc<PromptBroker> {
    let back: Arc<OnceLock<Weak<PromptBroker>>> = Arc::new(OnceLock::new());
    let callback = back.clone();
    let broker = PromptBroker::new(Box::new(move |message| {
        if let DaemonMsg::AuthPrompt { request_id, prompt } = message {
            let response = match prompt {
                AuthPromptKind::HostKeyUnknown {
                    fingerprint_sha256, ..
                } if fingerprint_sha256 == fingerprint => AuthResponse::HostKeyDecision {
                    accept: true,
                    remember: false,
                },
                _ => AuthResponse::Cancelled,
            };
            if let Some(broker) = callback.get().and_then(Weak::upgrade) {
                broker.deliver(request_id, response);
            }
        }
        true
    }));
    back.set(Arc::downgrade(&broker)).ok();
    broker
}
async fn send(stream: &mut (impl tokio::io::AsyncWrite + Unpin), request: Request) {
    let data = serde_json::to_vec(&request).unwrap();
    stream
        .write_all(&(data.len() as u32).to_le_bytes())
        .await
        .unwrap();
    stream.write_all(&[CONTROL]).await.unwrap();
    stream.write_all(&data).await.unwrap();
}
async fn frame(stream: &mut (impl tokio::io::AsyncRead + Unpin)) -> (u8, Vec<u8>) {
    tokio::time::timeout(Duration::from_secs(10), async {
        let size = stream.read_u32_le().await.unwrap() as usize;
        assert!(size <= MAX_FRAME);
        let kind = stream.read_u8().await.unwrap();
        let mut data = vec![0; size];
        stream.read_exact(&mut data).await.unwrap();
        (kind, data)
    })
    .await
    .unwrap()
}
async fn event(stream: &mut (impl tokio::io::AsyncRead + Unpin)) -> Event {
    loop {
        let (kind, bytes) = frame(stream).await;
        if kind == CONTROL {
            return serde_json::from_slice(&bytes).unwrap();
        }
    }
}
async fn hello(stream: &mut (impl tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin)) {
    send(stream, Request::Hello { version: VERSION }).await;
    assert!(matches!(event(stream).await, Event::Hello { .. }));
}
async fn input(stream: &mut (impl tokio::io::AsyncWrite + Unpin), data: &[u8]) {
    stream
        .write_all(&(data.len() as u32).to_le_bytes())
        .await
        .unwrap();
    stream.write_all(&[INPUT]).await.unwrap();
    stream.write_all(data).await.unwrap();
}
async fn until(stream: &mut (impl tokio::io::AsyncRead + Unpin), marker: &str) -> String {
    let mut output = Vec::new();
    loop {
        let (kind, bytes) = frame(stream).await;
        if kind == OUTPUT {
            output.extend_from_slice(&bytes[8..]);
        }
        let text = String::from_utf8_lossy(&output);
        if text.contains(marker) {
            return text.into_owned();
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires the isolated localhost SSH fixture"]
async fn native_install_and_disconnect_preserve_remote_shell() {
    use sha2::{Digest, Sha256};
    let fixture: serde_json::Value =
        serde_json::from_slice(&std::fs::read(std::env::var("KERO_SSH_FIXTURE").unwrap()).unwrap())
            .unwrap();
    let directory = fixture["directory"].as_str().unwrap();
    let fingerprint = fixture["fingerprint"].as_str().unwrap().to_owned();
    let spec: NativeSshSpec = serde_json::from_value(serde_json::json!({
        "host": "127.0.0.1", "port": fixture["port"], "user": fixture["user"],
        "auth_mode": "public-key", "identity_files": [format!("{directory}/client")],
        "known_hosts_files": [format!("{directory}/known_hosts")],
        "verify_host_keys": true, "connect_timeout_s": 5
    }))
    .unwrap();
    let reject_spec: NativeSshSpec = serde_json::from_value(serde_json::json!({
        "host": "127.0.0.1", "port": fixture["port"], "user": fixture["user"],
        "auth_mode": "public-key", "identity_files": [format!("{directory}/client")],
        "verify_host_keys": true, "connect_timeout_s": 5
    }))
    .unwrap();
    let reject = broker("SHA256:not-the-server".into());
    assert!(
        NativeConnection::connect(&reject_spec, &reject)
            .await
            .is_err(),
        "unknown host keys must not be silently trusted"
    );
    let broker = broker(fingerprint);
    let connection = NativeConnection::connect(&spec, &broker).await.unwrap();
    let mut jumped = spec.clone();
    jumped.jump = Some(Box::new(spec.clone()));
    let through_jump = NativeConnection::connect(&jumped, &broker).await.unwrap();
    assert_eq!(
        through_jump.command("printf jump-ok", &[]).await.unwrap(),
        b"jump-ok"
    );
    through_jump.disconnect().await;
    let platform = connection.platform().await.unwrap();
    let binary = std::fs::read(env!("CARGO_BIN_EXE_kero-daemon")).unwrap();
    let hash: String = Sha256::digest(&binary)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert!(
        connection
            .install(platform, &binary, "invalid-checksum")
            .await
            .is_err()
    );
    let remote = connection.install(platform, &binary, &hash).await.unwrap();
    // Installation is idempotent and never replaces an active executable.
    let mut uploads = 0;
    assert_eq!(
        connection
            .install_with_progress(platform, &binary, &hash, || uploads += 1)
            .await
            .unwrap(),
        remote
    );
    assert_eq!(uploads, 0, "reconnect uploaded an already verified binary");
    let state = tempfile::Builder::new()
        .prefix("kero-native-ssh-")
        .tempdir_in("/tmp")
        .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(state.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let state_path = state.path().to_str().unwrap();
    connection.start(&remote, state_path).await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::os::unix::net::UnixStream::connect(state.path().join("daemon.sock")).is_err() {
        assert!(Instant::now() < deadline);
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Cleanup is limited to the pid in this test-owned, private directory.
    struct Cleanup(u32);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            unsafe {
                libc::kill(self.0 as i32, libc::SIGTERM);
            }
        }
    }
    let _cleanup = Cleanup(
        std::fs::read_to_string(state.path().join("daemon.pid"))
            .unwrap()
            .parse()
            .unwrap(),
    );
    let mut stream = connection
        .bridge(&remote, state_path)
        .await
        .unwrap()
        .into_stream();
    hello(&mut stream).await;
    send(
        &mut stream,
        Request::Create {
            launch: Launch {
                session: uuid::Uuid::new_v4(),
                directory: "/tmp".into(),
                program: "/bin/sh".into(),
                arguments: vec!["-i".into()],
                environment: Default::default(),
                colors: [(0, [16, 16, 16]), (256, [220, 220, 220])].into(),
                cursor_style: None,
                history: None,
                size: Size {
                    columns: 80,
                    rows: 24,
                    cell_width: 8,
                    cell_height: 16,
                },
            },
        },
    )
    .await;
    let Event::Created { session } = event(&mut stream).await else {
        panic!("create")
    };
    send(
        &mut stream,
        Request::Attach {
            key: session.key.clone(),
        },
    )
    .await;
    assert!(matches!(event(&mut stream).await, Event::Attached { .. }));
    input(
        &mut stream,
        b"stty -echo; export KERO_SSH_STATE=retained; cd /; printf 'READY:%s\\n' $$\n",
    )
    .await;
    until(&mut stream, &format!("READY:{}", session.pid)).await;
    connection.disconnect().await;
    drop(stream);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let reconnect = Instant::now();
    let connection = NativeConnection::connect(&spec, &broker).await.unwrap();
    let mut stream = connection
        .bridge(&remote, state_path)
        .await
        .unwrap()
        .into_stream();
    hello(&mut stream).await;
    send(
        &mut stream,
        Request::Attach {
            key: session.key.clone(),
        },
    )
    .await;
    assert!(matches!(event(&mut stream).await, Event::Attached { .. }));
    input(
        &mut stream,
        b"printf 'RESTORED:%s:%s:%s\\n' $$ \"$KERO_SSH_STATE\" \"$PWD\"\n",
    )
    .await;
    until(&mut stream, &format!("RESTORED:{}:retained:/", session.pid)).await;
    eprintln!(
        "native SSH reconnect and first verified output: {} ms",
        reconnect.elapsed().as_millis()
    );
    send(&mut stream, Request::Terminate { key: session.key }).await;
    // Exited may race Terminated; both describe the same explicit close.
    while !matches!(event(&mut stream).await, Event::Terminated) {}
    drop(stream);
    // An expanded GUI keeps SSH alive when only the daemon crashes. A fresh
    // channel must restart that service, without silently creating a shell.
    let previous_pid = std::fs::read_to_string(state.path().join("daemon.pid"))
        .unwrap()
        .parse::<i32>()
        .unwrap();
    unsafe { libc::kill(previous_pid, libc::SIGTERM) };
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { libc::kill(previous_pid, 0) } == 0 {
        assert!(Instant::now() < deadline, "old daemon did not exit");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut restarted = connection
        .bridge(&remote, state_path)
        .await
        .unwrap()
        .into_stream();
    hello(&mut restarted).await;
    let _restarted_cleanup = Cleanup(
        std::fs::read_to_string(state.path().join("daemon.pid"))
            .unwrap()
            .parse()
            .unwrap(),
    );
    send(&mut restarted, Request::List).await;
    assert!(
        matches!(event(&mut restarted).await, Event::Sessions { sessions } if sessions.is_empty())
    );
    assert_ne!(_restarted_cleanup.0 as i32, previous_pid);
    connection.disconnect().await;
}

/// The target and binary are supplied explicitly by the operator. All mutable
/// test data lives beneath a fresh UUID directory; existing host services and
/// the normal daemon namespace are never touched.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires an explicitly authorized external SSH target and matching artifact"]
async fn external_host_install_files_git_checkpoint_and_reconnect() {
    use kero_daemon::host::{HostPath, HostRequest, HostResponse};
    use sha2::{Digest, Sha256};
    let spec: NativeSshSpec = serde_json::from_slice(
        &std::fs::read(std::env::var("KERO_EXTERNAL_SSH_SPEC").unwrap()).unwrap(),
    )
    .unwrap();
    let binary = std::fs::read(std::env::var("KERO_EXTERNAL_DAEMON").unwrap()).unwrap();
    // The user's existing known_hosts is the trust anchor. Unknown or changed
    // keys cannot be silently accepted by this test.
    let prompts = broker(String::new());
    let connection = NativeConnection::connect(&spec, &prompts).await.unwrap();
    let platform = connection.platform().await.unwrap();
    let hash: String = Sha256::digest(&binary)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let remote = connection.install(platform, &binary, &hash).await.unwrap();
    let home = String::from_utf8(
        connection
            .command("printf '%s' \"$HOME\"", &[])
            .await
            .unwrap(),
    )
    .unwrap();
    let directory = format!("{home}/.cache/kero-validation-{}", uuid::Uuid::new_v4());
    let quote = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
    connection
        .command(
            &format!("umask 077; mkdir -p {}/project", quote(&directory)),
            &[],
        )
        .await
        .unwrap();
    connection.start(&remote, &directory).await.unwrap();
    eprintln!("external fixture: {directory}");
    let test_directory = directory.clone();
    let cleanup_spec = spec.clone();
    let result = tokio::spawn(async move {
        let directory = test_directory;
        let mut stream = connection.bridge(&remote, &directory).await?.into_stream();
        hello(&mut stream).await;
        send(&mut stream, Request::Create { launch: Launch {
            session: uuid::Uuid::new_v4(), directory: format!("{directory}/project"),
            program: "/bin/sh".into(), arguments: vec!["-i".into()], environment: Default::default(), colors: [(0, [16, 16, 16]), (256, [220, 220, 220])].into(),cursor_style:None,history:None,
            size: Size { columns: 80, rows: 24, cell_width: 8, cell_height: 16 },
        }}).await;
        let Event::Created { session } = event(&mut stream).await else { anyhow::bail!("create failed") };
        send(&mut stream, Request::Attach { key: session.key.clone() }).await;
        assert!(matches!(event(&mut stream).await, Event::Attached { .. }));
        input(&mut stream, b"stty -echo; export KERO_VERIFY=linux; (sleep 1; printf done > background.txt) & printf 'READY:%s\\n' $$\n").await;
        until(&mut stream, &format!("READY:{}", session.pid)).await;
        let command = format!("burst='{}'; printf 'SSH_BURST:%s\\n' \"${{#burst}}\"\n", "x".repeat(500));
        let mut burst = Vec::new();
        for byte in command.bytes() { burst.extend_from_slice(&1u32.to_le_bytes()); burst.push(INPUT); burst.push(byte); }
        stream.write_all(&burst).await?;
        until(&mut stream, "SSH_BURST:500").await;
        // Leave the alternate screen active and split an SGR across the loss
        // of the entire native SSH transport.
        input(&mut stream, "printf '\033[?1049h\033[2;4H中文 TUI\033[38;2;12;'\n".as_bytes()).await;
        until(&mut stream, "中文 TUI").await;
        connection.disconnect().await; drop(stream);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let started = Instant::now();
        let next = NativeConnection::connect(&spec, &prompts).await?;
        let mut stream = next.bridge(&remote, &directory).await?.into_stream(); hello(&mut stream).await;
        send(&mut stream, Request::Attach { key: session.key.clone() }).await;
        assert!(matches!(event(&mut stream).await, Event::Attached { .. }));
        let mut checkpoint = Vec::new();
        loop {
            let (kind, bytes) = frame(&mut stream).await;
            if kind == CHECKPOINT { checkpoint.extend_from_slice(&bytes[9..]); if bytes[8] == 1 { break; } }
        }
        let mut restored = kero_terminal_state::TerminalState::new(80, 24, 8, 16);
        restored.feed(&checkpoint);
        assert!(restored.screen_text().contains("中文 TUI"), "{}", restored.screen_text());
        input(&mut stream, b"printf '34;56mRESTORED:%s:%s:%s\\n' $$ \"$KERO_VERIFY\" \"$PWD\"\n").await;
        until(&mut stream, &format!("RESTORED:{}:linux:{directory}/project", session.pid)).await;
        eprintln!("external native SSH {:?} reconnect+checkpoint+verified output: {} ms", platform, started.elapsed().as_millis());
        let mut operations = next.bridge(&remote, &directory).await?.into_stream(); hello(&mut operations).await;
        let root = HostPath { host: session.key.host, path: format!("{directory}/project").into() };
        for args in [vec!["init"], vec!["-c","user.name=Kero verification","-c","user.email=kero-test@localhost","add","background.txt"],vec!["-c","user.name=Kero verification","-c","user.email=kero-test@localhost","commit","-m","test fixture"],vec!["checkout","-b","test-branch"],vec!["status","--porcelain"]] {
            send(&mut operations, Request::Host { request: HostRequest::Git { path: root.clone(), arguments: args.iter().map(|s|s.to_string()).collect() }}).await;
            let Event::Host { response: HostResponse::Git { output } } = event(&mut operations).await else { anyhow::bail!("git response") };
            assert_eq!(output.status,Some(0),"{:?}",output);
        }
        send(&mut operations, Request::Host { request: HostRequest::Read { path: HostPath { host: root.host, path: root.path.join("background.txt") } }}).await;
        assert!(matches!(event(&mut operations).await, Event::Host { response: HostResponse::File { .. } }));
        let started=Instant::now();let mut received=0usize;let mut tail=Vec::new();
        input(&mut stream,b"printf '\\033[?1049l'; python3 -c \"import sys,time; start=time.monotonic(); sys.stdout.write(('X'*127+'\\n')*32768); sys.stdout.write('KERO_BENCH_DONE\\n'); sys.stdout.flush(); open('bench-seconds','w').write(str(time.monotonic()-start))\"\n").await;
        let mut detached=false;
        loop {
            let size=match tokio::time::timeout(Duration::from_secs(15),stream.read_u32_le()).await.unwrap() {
                Ok(size)=>size as usize,
                Err(error) if error.kind()==std::io::ErrorKind::UnexpectedEof => {detached=true;break},
                Err(error)=>panic!("benchmark transport: {error}")
            };
            assert!(size<=MAX_FRAME);
            let kind=stream.read_u8().await.unwrap();let mut bytes=vec![0;size];stream.read_exact(&mut bytes).await.unwrap();
            if kind==OUTPUT {
                received+=bytes.len()-8;tail.extend_from_slice(&bytes[8..]);
                if tail.windows(b"KERO_BENCH_DONE".len()).any(|w|w==b"KERO_BENCH_DONE") {break}
                if tail.len()>128 {tail.drain(..tail.len()-128);}
            }
        }
        if detached {
            // A fast producer may overrun a bounded WAN subscriber. Verify
            // its background output completes and state reattachment works.
            tokio::time::sleep(Duration::from_millis(500)).await;
            stream=next.bridge(&remote,&directory).await?.into_stream();hello(&mut stream).await;
            send(&mut stream,Request::Attach{key:session.key.clone()}).await;
            assert!(matches!(event(&mut stream).await,Event::Attached{..}));
            let mut checkpoint=Vec::new();
            loop {let (kind,bytes)=frame(&mut stream).await;if kind==CHECKPOINT {checkpoint.extend_from_slice(&bytes[9..]);if bytes[8]==1{break}}}
            let mut restored=kero_terminal_state::TerminalState::new(80,24,8,16);restored.feed(&checkpoint);
            assert!(restored.screen_text().contains("KERO_BENCH_DONE"),"overload did not restore the completed output");
        }
        let seconds=next.command(&format!("cat '{directory}/project/bench-seconds'"),&[]).await?;
        let seconds=String::from_utf8(seconds)?.parse::<f64>()?;
        eprintln!("external 4 MiB PTY producer completed in {:.3} s ({:.2} MiB/s); WAN received {} bytes before completion/detach; bounded subscriber detached: {}; verified restoration in {} ms",seconds,4.0/seconds,received,detached,started.elapsed().as_millis());
        let memory=next.command(&format!("ps -o rss= -p $(cat '{directory}/daemon.pid')"),&[]).await?;
        eprintln!("external daemon RSS after output: {} KiB",String::from_utf8_lossy(&memory).trim());
        send(&mut stream, Request::Terminate { key: session.key }).await;
        while !matches!(event(&mut stream).await, Event::Terminated) {}
        next.disconnect().await;
        Ok::<(), anyhow::Error>(())
    }).await;
    let cleanup = NativeConnection::connect(&cleanup_spec, &broker(String::new()))
        .await
        .unwrap();
    cleanup.command(&format!("if [ -f {0}/daemon.pid ]; then kill $(cat {0}/daemon.pid) 2>/dev/null || true; fi; rm -rf {0}",quote(&directory)), &[]).await.unwrap();
    cleanup.disconnect().await;
    result.unwrap().unwrap();
}
