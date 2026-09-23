use kero_daemon::host::{HostPath, HostRequest, HostResponse};
use kero_daemon::protocol::*;
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use uuid::Uuid;

fn daemon_binary() -> std::ffi::OsString {
    std::env::var_os("KERO_DAEMON_TEST_BINARY")
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_kero-daemon").into())
}

struct Daemon {
    child: Child,
    directory: tempfile::TempDir,
}
impl Daemon {
    fn start() -> Self {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let child = Command::new(daemon_binary())
            .env("SHELL", "/bin/sh")
            .arg("--serve")
            .arg("--state-dir")
            .arg(directory.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let result = Self { child, directory };
        let deadline = Instant::now() + Duration::from_secs(10);
        while UnixStream::connect(result.directory.path().join("daemon.sock")).is_err() {
            assert!(Instant::now() < deadline, "daemon did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        result
    }
    fn connect(&self) -> Client {
        Client::connect(self.directory.path().join("daemon.sock"))
    }
}
impl Drop for Daemon {
    fn drop(&mut self) {
        // Terminate only test-owned sessions before shutting down the fixture.
        if let Ok(mut stream) = UnixStream::connect(self.directory.path().join("daemon.sock")) {
            stream.set_read_timeout(Some(Duration::from_secs(1))).ok();
            send(&mut stream, &Request::Hello { version: VERSION });
            let _ = read_frame(&mut stream);
            send(&mut stream, &Request::List);
            if let Ok((_, bytes)) = read_frame(&mut stream) {
                if let Ok(Event::Sessions { sessions }) = serde_json::from_slice(&bytes) {
                    for session in sessions {
                        send(&mut stream, &Request::Terminate { key: session.key });
                        let _ = read_frame(&mut stream);
                    }
                }
            }
        }
        self.child.kill().ok();
        self.child.wait().ok();
    }
}
struct Client {
    stream: UnixStream,
    host: Uuid,
    instance: Uuid,
}
impl Client {
    fn connect(path: std::path::PathBuf) -> Self {
        let mut stream = UnixStream::connect(path).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        send(&mut stream, &Request::Hello { version: VERSION });
        let (_, bytes) = read_frame(&mut stream).unwrap();
        let Event::Hello { host, instance, .. } = serde_json::from_slice(&bytes).unwrap() else {
            panic!("no hello")
        };
        Self {
            stream,
            host,
            instance,
        }
    }
    fn request(&mut self, request: Request) -> Event {
        send(&mut self.stream, &request);
        self.event()
    }
    fn event(&mut self) -> Event {
        loop {
            let (kind, bytes) = read_frame(&mut self.stream).unwrap();
            if kind == CONTROL {
                return serde_json::from_slice(&bytes).unwrap();
            }
        }
    }
    fn spawn(&mut self) -> SessionInfo {
        let launch = Launch {
            session: Uuid::new_v4(),
            directory: "/tmp".into(),
            program: "/bin/sh".into(),
            arguments: vec!["-i".into()],
            environment: BTreeMap::new(),
            colors: BTreeMap::from([(0, [0, 0, 0]), (256, [240, 241, 242]), (257, [12, 13, 14])]),
            cursor_style: None,
            history: None,
            size: Size {
                columns: 80,
                rows: 24,
                cell_width: 8,
                cell_height: 16,
            },
        };
        let Event::Created { session } = self.request(Request::Create { launch }) else {
            panic!("no session")
        };
        session
    }
    fn attach(&mut self, key: &SessionKey) {
        assert!(matches!(
            self.request(Request::Attach { key: key.clone() }),
            Event::Attached { .. }
        ));
    }
    fn input(&mut self, bytes: &[u8]) {
        write_frame(&mut self.stream, INPUT, bytes).unwrap();
    }
    fn until(&mut self, needle: &str) -> Vec<u8> {
        let mut output = Vec::new();
        while !String::from_utf8_lossy(&output).contains(needle) {
            let (kind, bytes) = read_frame(&mut self.stream).unwrap_or_else(|e| {
                panic!(
                    "waiting for {needle:?}: {e}; received {:?}",
                    String::from_utf8_lossy(&output)
                )
            });
            if kind == OUTPUT {
                output.extend_from_slice(&bytes[8..]);
            }
        }
        output
    }
}
fn send(stream: &mut UnixStream, request: &Request) {
    write_frame(stream, CONTROL, &serde_json::to_vec(request).unwrap()).unwrap();
}

#[test]
fn disconnect_keeps_shell_pid_environment_directory_and_background_job() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    client.attach(&session.key);
    client.input(b"stty -echo; export KERO_TEST_STATE=retained; cd /; sleep 60 &\nprintf 'READY:%s:%s\\n' $$ $!\n");
    let output = client.until(&format!("READY:{}:", session.pid));
    assert!(String::from_utf8_lossy(&output).contains(&format!("READY:{}:", session.pid)));
    drop(client);
    std::thread::sleep(Duration::from_millis(80));
    assert_eq!(unsafe { libc::kill(session.pid as i32, 0) }, 0);
    let mut client = daemon.connect();
    client.attach(&session.key);
    client.input(b"printf 'RESTORED:%s:%s:%s\\n' $$ \"$KERO_TEST_STATE\" \"$PWD\"; jobs; printf 'CHECK_DONE\\n'\n");
    let output = client.until("CHECK_DONE");
    let output = String::from_utf8_lossy(&output);
    assert!(
        output.contains(&format!("RESTORED:{}:retained:/", session.pid)),
        "{output}"
    );
    assert!(output.contains("sleep 60"), "{output}");
}

#[test]
fn generation_and_host_identity_are_required_for_every_session_operation() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    for bad in [
        SessionKey {
            instance: Uuid::new_v4(),
            ..session.key.clone()
        },
        SessionKey {
            host: Uuid::new_v4(),
            ..session.key.clone()
        },
    ] {
        assert!(matches!(
            client.request(Request::Terminate { key: bad.clone() }),
            Event::Error { .. }
        ));
        assert!(matches!(
            client.request(Request::Attach { key: bad }),
            Event::Error { .. }
        ));
    }
    assert_eq!(unsafe { libc::kill(session.pid as i32, 0) }, 0);
    let mut second = daemon.connect();
    assert_eq!(client.instance, second.instance);
    client.attach(&session.key);
    assert!(matches!(
        second.request(Request::Attach { key: session.key }),
        Event::Error { .. }
    ));
}

#[test]
fn version_mismatch_and_second_daemon_do_not_disrupt_existing_jobs() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    let status = Command::new(daemon_binary())
        .arg("--serve")
        .arg("--state-dir")
        .arg(daemon.directory.path())
        .output()
        .unwrap();
    assert!(!status.status.success());
    let mut stream = UnixStream::connect(daemon.directory.path().join("daemon.sock")).unwrap();
    send(
        &mut stream,
        &Request::Hello {
            version: VERSION + 1,
        },
    );
    let (_, bytes) = read_frame(&mut stream).unwrap();
    assert!(
        matches!(serde_json::from_slice::<Event>(&bytes).unwrap(), Event::Error { code, .. } if code == "version_mismatch")
    );
    client.attach(&session.key);
    client.input(b"printf 'STILL_ALIVE\\n'\n");
    client.until("STILL_ALIVE");
}

#[test]
fn host_paths_reject_another_host_and_save_detects_conflicts() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let path = daemon.directory.path().join("document.txt");
    std::fs::write(&path, "original").unwrap();
    let foreign = HostPath {
        host: Uuid::new_v4(),
        path: path.clone(),
    };
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::Remove {
                path: foreign,
                recursive: false
            }
        }),
        Event::Error { .. }
    ));
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "original");
    let own = HostPath {
        host: client.host,
        path: path.clone(),
    };
    let Event::Host {
        response: HostResponse::File { sha256, .. },
    } = client.request(Request::Host {
        request: HostRequest::Read { path: own.clone() },
    })
    else {
        panic!("read failed")
    };
    std::fs::write(&path, "external edit").unwrap();
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::Write {
                path: own,
                data: "bmV3".into(),
                expected_sha256: sha256
            }
        }),
        Event::Error { .. }
    ));
    assert_eq!(std::fs::read_to_string(path).unwrap(), "external edit");
}

#[test]
fn output_sequence_covers_raw_bytes_and_detach_does_not_kill() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    let Event::Attached { session: attached } = client.request(Request::Attach {
        key: session.key.clone(),
    }) else {
        panic!("attach")
    };
    let mut position = attached.sequence;
    client.input(
        b"stty -echo; printf '\\033[31m\\344\\270\\255\\346\\226\\207\\033[0mSEQUENCE_DONE\\n'\n",
    );
    let mut output = Vec::new();
    while !String::from_utf8_lossy(&output).contains("\u{1b}[31m中文\u{1b}[0mSEQUENCE_DONE") {
        let (kind, data) = read_frame(&mut client.stream).unwrap();
        if kind == OUTPUT {
            let end = u64::from_le_bytes(data[..8].try_into().unwrap());
            assert_eq!(end, position + (data.len() - 8) as u64);
            position = end;
            output.extend_from_slice(&data[8..]);
        }
    }
    assert!(matches!(client.request(Request::Detach), Event::Detached));
    assert_eq!(unsafe { libc::kill(session.pid as i32, 0) }, 0);
}

#[test]
fn oversized_frames_are_rejected_before_payload_allocation() {
    let mut bytes = ((MAX_FRAME as u32) + 1).to_le_bytes().to_vec();
    bytes.push(CONTROL);
    assert_eq!(
        read_frame(&mut bytes.as_slice()).unwrap_err().kind(),
        std::io::ErrorKind::InvalidData
    );
}

#[test]
fn stdio_bridge_eof_detaches_without_starting_another_daemon() {
    let daemon = Daemon::start();
    let mut bridge = Command::new(daemon_binary())
        .arg("--stdio")
        .arg("--state-dir")
        .arg(daemon.directory.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = bridge.stdin.take().unwrap();
    let mut output = bridge.stdout.take().unwrap();
    write_frame(
        &mut input,
        CONTROL,
        &serde_json::to_vec(&Request::Hello { version: VERSION }).unwrap(),
    )
    .unwrap();
    input.flush().unwrap();
    let (_, bytes) = read_frame(&mut output).unwrap();
    assert!(matches!(
        serde_json::from_slice::<Event>(&bytes).unwrap(),
        Event::Hello { .. }
    ));
    drop(input);
    let mut rest = Vec::new();
    output.read_to_end(&mut rest).unwrap();
    assert!(bridge.wait().unwrap().success());
}

#[test]
fn slow_client_cannot_block_background_output_and_reconnect_is_fast() {
    let daemon = Daemon::start();
    let marker = daemon.directory.path().join("flood-complete");
    let mut client = daemon.connect();
    let session = client.spawn();
    client.attach(&session.key);
    client.input(
        format!(
            "stty -echo; head -c 33554432 /dev/zero; printf done > '{}'\n",
            marker.display()
        )
        .as_bytes(),
    );
    let begin = Instant::now();
    // Deliberately do not read this client's socket. Its bounded queue must
    // disconnect it while the child continues writing all 32 MiB to the PTY.
    while !marker.exists() {
        assert!(
            begin.elapsed() < Duration::from_secs(10),
            "slow client blocked the job"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let elapsed = begin.elapsed();
    let rss = Command::new("/bin/ps")
        .args(["-o", "rss=", "-p", &daemon.child.id().to_string()])
        .output()
        .unwrap();
    eprintln!(
        "32 MiB flood with stalled subscriber: {:.1} MiB/s; daemon RSS {} KiB",
        32.0 / elapsed.as_secs_f64(),
        String::from_utf8_lossy(&rss.stdout).trim()
    );
    let reconnect = Instant::now();
    let mut next = loop {
        let mut next = daemon.connect();
        if matches!(
            next.request(Request::Attach {
                key: session.key.clone()
            }),
            Event::Attached { .. }
        ) {
            break next;
        }
        assert!(reconnect.elapsed() < Duration::from_secs(12), "slow detach");
        std::thread::sleep(Duration::from_millis(10));
    };
    next.input(b"printf 'RECONNECTED:%s\\n' $$\n");
    next.until(&format!("RECONNECTED:{}", session.pid));
    eprintln!(
        "local reconnect and verified output: {} us",
        reconnect.elapsed().as_micros()
    );
}

#[test]
fn explicit_termination_ends_a_shell_ignoring_hangup() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    client.attach(&session.key);
    client.input(b"stty -echo; trap '' HUP; printf 'IGNORE_READY:%s\\n' $$\n");
    client.until(&format!("IGNORE_READY:{}", session.pid));
    let mut control = daemon.connect();
    assert!(matches!(
        control.request(Request::Terminate { key: session.key }),
        Event::Terminated
    ));
    let deadline = Instant::now() + Duration::from_secs(3);
    while unsafe { libc::kill(session.pid as i32, 0) } == 0 {
        assert!(
            Instant::now() < deadline,
            "explicit close did not end shell"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn file_operations_git_and_watch_share_the_host_identity() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let root = daemon.directory.path().join("project");
    let path = |path| HostPath {
        host: client.host,
        path,
    };
    let root_path = path(root.clone());
    let source = path(root.join("source.txt"));
    let destination = path(root.join("renamed.txt"));
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::CreateDirectory {
                path: root_path.clone()
            }
        }),
        Event::Host {
            response: HostResponse::Done
        }
    ));
    let mut watcher = daemon.connect();
    assert!(matches!(
        watcher.request(Request::Watch {
            paths: vec![root_path.clone()]
        }),
        Event::Watching
    ));
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::CreateFile {
                path: source.clone()
            }
        }),
        Event::Host {
            response: HostResponse::Done
        }
    ));
    let Event::Changed { paths } = watcher.event() else {
        panic!("no filesystem change")
    };
    assert!(paths.iter().all(|path| path.host == client.host));
    let Event::Host {
        response: HostResponse::File { sha256, .. },
    } = client.request(Request::Host {
        request: HostRequest::Read {
            path: source.clone(),
        },
    })
    else {
        panic!("read")
    };
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::Write {
                path: source.clone(),
                data: "aGVsbG8K".into(),
                expected_sha256: sha256
            }
        }),
        Event::Host {
            response: HostResponse::Written { .. }
        }
    ));
    assert_eq!(std::fs::read_to_string(&source.path).unwrap(), "hello\n");
    for arguments in [
        vec!["init"],
        vec!["add", "source.txt"],
        vec![
            "-c",
            "user.name=Kero Test",
            "-c",
            "user.email=kero-test@localhost",
            "commit",
            "-m",
            "test",
        ],
        vec!["checkout", "-b", "verification"],
    ] {
        let Event::Host {
            response: HostResponse::Git { output },
        } = client.request(Request::Host {
            request: HostRequest::Git {
                path: root_path.clone(),
                arguments: arguments.iter().map(|a| a.to_string()).collect(),
            },
        })
        else {
            panic!("git response")
        };
        assert!(output.success(), "{}", output.stderr_trimmed());
    }
    let Event::Host {
        response: HostResponse::Repository {
            path: Some(repository),
        },
    } = client.request(Request::Host {
        request: HostRequest::Repository {
            path: source.clone(),
        },
    })
    else {
        panic!("repo root")
    };
    assert_eq!(repository.host, client.host);
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::Rename {
                path: source,
                destination: destination.clone()
            }
        }),
        Event::Host {
            response: HostResponse::Done
        }
    ));
    assert!(matches!(
        client.request(Request::Host {
            request: HostRequest::Remove {
                path: destination,
                recursive: false
            }
        }),
        Event::Host {
            response: HostResponse::Done
        }
    ));
    send(&mut watcher.stream, &Request::Detach);
    while !matches!(watcher.event(), Event::Detached) {}
}

#[test]
fn daemon_restart_keeps_host_identity_but_rejects_old_process_identity() {
    let mut daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    client.request(Request::Terminate {
        key: session.key.clone(),
    });
    drop(client);
    daemon.child.kill().unwrap();
    daemon.child.wait().unwrap();
    daemon.child = Command::new(daemon_binary())
        .arg("--serve")
        .arg("--state-dir")
        .arg(daemon.directory.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while UnixStream::connect(daemon.directory.path().join("daemon.sock")).is_err() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut next = daemon.connect();
    assert_eq!(session.key.host, next.host);
    assert_ne!(session.key.instance, next.instance);
    assert!(matches!(
        next.request(Request::Attach { key: session.key }),
        Event::Error { .. }
    ));
    let Event::Sessions { sessions } = next.request(Request::List) else {
        panic!("list")
    };
    assert!(sessions.is_empty(), "daemon restart must not rerun tasks");
}

#[test]
fn cold_restart_restores_history_and_directory_without_reexecuting_task() {
    let mut daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    client.attach(&session.key);
    let working = daemon.directory.path().join("working");
    std::fs::create_dir(&working).unwrap();
    client.input(
        format!(
            "stty -echo; cd '{}'; export KERO_OLD_TASK=old; printf 'COLD_HISTORY_MARKER\\n'\n",
            working.display()
        )
        .as_bytes(),
    );
    client.until("COLD_HISTORY_MARKER");
    let saved = daemon
        .directory
        .path()
        .join(format!("{}.json", session.key.session));
    let deadline = Instant::now() + Duration::from_secs(6);
    loop {
        if let Ok(bytes) = std::fs::read(&saved) {
            if let Ok(record) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                if record["directory"]
                    .as_str()
                    .and_then(|p| std::fs::canonicalize(p).ok())
                    == std::fs::canonicalize(&working).ok()
                {
                    break;
                }
            }
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(50));
    }
    daemon.child.kill().unwrap();
    daemon.child.wait().unwrap();
    drop(client);
    daemon.child = Command::new(daemon_binary())
        .env("SHELL", "/bin/sh")
        .args(["--serve", "--state-dir"])
        .arg(daemon.directory.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut client = loop {
        if let Ok(mut socket) = UnixStream::connect(daemon.directory.path().join("daemon.sock")) {
            socket
                .set_read_timeout(Some(Duration::from_millis(200)))
                .unwrap();
            if write_frame(
                &mut socket,
                CONTROL,
                &serde_json::to_vec(&Request::Hello { version: VERSION }).unwrap(),
            )
            .is_ok()
                && read_frame(&mut socket).is_ok()
            {
                break daemon.connect();
            }
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    };
    let marker = daemon.directory.path().join("TASK_MUST_NOT_RESTART");
    let Event::Created { session: fresh } = client.request(Request::Create {
        launch: Launch {
            session: session.key.session,
            directory: "/tmp".into(),
            program: "/bin/sh".into(),
            arguments: vec!["-c".into(), format!("touch '{}'", marker.display())],
            environment: BTreeMap::new(),
            colors: Default::default(),
            cursor_style: None,
            history: None,
            size: session.size,
        },
    }) else {
        panic!("create")
    };
    assert_ne!(fresh.pid, session.pid);
    assert_ne!(fresh.key.instance, session.key.instance);
    assert_eq!(
        std::fs::canonicalize(&fresh.directory).unwrap(),
        std::fs::canonicalize(&working).unwrap()
    );
    client.attach(&fresh.key);
    let mut checkpoint = Vec::new();
    loop {
        let (kind, bytes) = read_frame(&mut client.stream).unwrap();
        if kind == CHECKPOINT {
            checkpoint.extend_from_slice(&bytes[9..]);
            if bytes[8] == 1 {
                break;
            }
        }
    }
    let mut screen = kero_terminal_state::TerminalState::new(80, 24, 8, 16);
    screen.feed(&checkpoint);
    assert!(String::from_utf8_lossy(&checkpoint).contains("COLD_HISTORY_MARKER"));
    assert!(String::from_utf8_lossy(&checkpoint).contains("new shell"));
    client.input(b"printf 'NEW_SHELL:%s:%s\\n' $$ \"${KERO_OLD_TASK-unset}\"\n");
    client.until(&format!("NEW_SHELL:{}:unset", fresh.pid));
    assert!(!marker.exists());
}

#[test]
fn relay_checkpoint_barrier_excludes_already_replayed_output() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    client.attach(&session.key);
    client.input(b"stty -echo; printf 'BEFORE_SNAPSHOT\\n'\n");
    client.until("BEFORE_SNAPSHOT");
    send(
        &mut client.stream,
        &Request::Checkpoint {
            key: session.key.clone(),
        },
    );
    let mut snapshot = Vec::new();
    let mut sequence = None;
    loop {
        let (kind, bytes) = read_frame(&mut client.stream).unwrap();
        if kind == CHECKPOINT {
            let offset = u64::from_le_bytes(bytes[..8].try_into().unwrap());
            if let Some(previous) = sequence {
                assert_eq!(offset, previous)
            }
            sequence = Some(offset);
            snapshot.extend_from_slice(&bytes[9..]);
            if bytes[8] == 1 {
                break;
            }
        }
    }
    assert!(String::from_utf8_lossy(&snapshot).contains("BEFORE_SNAPSHOT"));
    client.input(b"printf 'AFTER_SNAPSHOT\\n'\n");
    let mut sequence = sequence.unwrap();
    let mut output = Vec::new();
    loop {
        let (kind, bytes) = read_frame(&mut client.stream).unwrap();
        if kind == OUTPUT {
            let offset = u64::from_le_bytes(bytes[..8].try_into().unwrap());
            assert_eq!(offset, sequence + (bytes.len() - 8) as u64);
            sequence = offset;
            output.extend_from_slice(&bytes[8..]);
            if String::from_utf8_lossy(&output).contains("AFTER_SNAPSHOT") {
                break;
            }
        }
    }
    assert!(!String::from_utf8_lossy(&output).contains("BEFORE_SNAPSHOT"));
}

#[test]
fn rapid_single_byte_input_frames_preserve_complete_command() {
    let daemon = Daemon::start();
    let mut client = daemon.connect();
    let session = client.spawn();
    client.attach(&session.key);
    client.input(b"stty -echo; printf 'BURST_READY\\n'\n");
    client.until("\r\nBURST_READY\r\n");
    let command = format!(
        "value='{}'; printf 'BURST_LENGTH:%s\\n' \"${{#value}}\"\n",
        "x".repeat(500)
    );
    // Many key frames can arrive in a single SSH network read.
    let mut burst = Vec::new();
    for byte in command.bytes() {
        burst.extend_from_slice(&1u32.to_le_bytes());
        burst.push(INPUT);
        burst.push(byte);
    }
    client.stream.write_all(&burst).unwrap();
    client.until("BURST_LENGTH:500");
}

#[test]
fn image_upload_is_host_scoped_private_and_removed_when_session_ends() {
    use base64::{Engine, engine::general_purpose::STANDARD};
    let daemon = Daemon::start();
    let mut control = daemon.connect();
    let session = control.spawn();
    let png = STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG9sAAAAASUVORK5CYII=").unwrap();
    let mut wrong = session.key.clone();
    wrong.host = Uuid::new_v4();
    assert!(matches!(
        control.request(Request::UploadImage {
            key: wrong,
            data: STANDARD.encode(&png)
        }),
        Event::Error { .. }
    ));
    let Event::ImageUploaded { path, sha256 } = control.request(Request::UploadImage {
        key: session.key.clone(),
        data: STANDARD.encode(&png),
    }) else {
        panic!("upload failed")
    };
    assert_eq!(std::fs::read(&path).unwrap(), png);
    assert_eq!(sha256.len(), 64);
    assert_eq!(
        std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let mut attached = daemon.connect();
    attached.attach(&session.key);
    attached.input(
        br"stty -echo -icanon min 1; printf '\033[?2004h\nPASTE_READY\n'; od -An -tx1 -N 16",
    );
    attached.input(b"\n");
    attached.until("\r\nPASTE_READY\r\n");
    send(
        &mut attached.stream,
        &Request::Paste {
            key: session.key.clone(),
            text: "FILE".into(),
        },
    );
    let output = attached.until("7e\r\n");
    let hex = String::from_utf8_lossy(&output)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        hex.contains("1b 5b 32 30 30 7e 46 49 4c 45 1b 5b 32 30 31 7e"),
        "{hex}"
    );
    drop(attached);
    assert!(
        std::path::Path::new(&path).exists(),
        "detach deleted an attachment"
    );
    assert!(matches!(
        control.request(Request::Terminate { key: session.key }),
        Event::Terminated
    ));
    assert!(!std::path::Path::new(&path).exists());
}

#[test]
fn naturally_exited_detached_sessions_are_reaped() {
    let daemon = Daemon::start();
    let mut control = daemon.connect();
    let session = control.spawn();
    let mut attached = daemon.connect();
    attached.attach(&session.key);
    attached.input(b"exit\n");
    while !matches!(attached.event(), Event::Exited { .. }) {}
    drop(attached);
    let deadline = Instant::now() + Duration::from_secs(6);
    loop {
        let Event::Sessions { sessions } = control.request(Request::List) else {
            panic!("list")
        };
        if sessions.is_empty() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "exited session retained its PTY/state"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}
