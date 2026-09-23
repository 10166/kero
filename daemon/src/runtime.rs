use crate::{protocol::*, session::Session};
use base64::{Engine, engine::general_purpose::STANDARD};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use std::time::Duration;
use uuid::Uuid;

const MAX_SESSIONS: usize = 256;
const MAX_CLIENTS: usize = 64;

pub struct Runtime {
    pub host: Uuid,
    directory: PathBuf,
    pub instance: Uuid,
    sessions: Mutex<HashMap<Uuid, Arc<Session>>>,
    // Serialize host operations so two GUI saves cannot both pass the hash
    // precondition before either write commits. External writers remain a race.
    host_operations: Mutex<()>,
    clients: AtomicUsize,
}

/// The lifetime lock is acquired before unlinking any stale socket. Starting a
/// second version never takes the active daemon's address away from its jobs.
pub struct Endpoint {
    pub listener: UnixListener,
    _lock: File,
    pub host: Uuid,
}
impl Endpoint {
    pub fn bind(directory: &Path) -> anyhow::Result<Self> {
        private_directory(directory)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(directory.join("daemon.lock"))?;
        anyhow::ensure!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0,
            "Kero daemon is already running; active sessions were not interrupted"
        );
        let host_path = directory.join("host-id");
        let host = match fs::read_to_string(&host_path) {
            Ok(value) => Uuid::parse_str(value.trim())?,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                use std::io::Write;
                let host = Uuid::new_v4();
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&host_path)?;
                writeln!(file, "{host}")?;
                file.sync_all()?;
                host
            }
            Err(e) => return Err(e.into()),
        };
        let socket = directory.join("daemon.sock");
        match fs::symlink_metadata(&socket) {
            Ok(metadata) => {
                anyhow::ensure!(
                    metadata.file_type().is_socket()
                        && metadata.uid() == unsafe { libc::geteuid() },
                    "refusing to remove non-socket or foreign endpoint"
                );
                fs::remove_file(&socket)?;
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let listener = UnixListener::bind(socket)?;
        fs::write(directory.join("daemon.pid"), std::process::id().to_string())?;
        fs::set_permissions(
            directory.join("daemon.sock"),
            fs::Permissions::from_mode(0o600),
        )?;
        Ok(Self {
            listener,
            _lock: lock,
            host,
        })
    }
}

pub fn private_directory(path: &Path) -> anyhow::Result<()> {
    anyhow::ensure!(path.is_absolute(), "state directory must be absolute");
    if !path.exists() {
        // create_dir_all honors umask only for the final privacy check below.
        fs::create_dir_all(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    let metadata = fs::symlink_metadata(path)?;
    anyhow::ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "state path must be a directory, not a symlink"
    );
    anyhow::ensure!(
        metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0,
        "state directory must be owned by this user with mode 0700"
    );
    Ok(())
}

impl Runtime {
    pub fn new(host: Uuid, directory: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            host,
            directory,
            instance: Uuid::new_v4(),
            sessions: Mutex::new(HashMap::new()),
            host_operations: Mutex::new(()),
            clients: AtomicUsize::new(0),
        })
    }
    pub fn serve(self: Arc<Self>, endpoint: Endpoint) -> anyhow::Result<()> {
        let runtime = Arc::downgrade(&self);
        std::thread::spawn(move || {
            let mut versions = HashMap::new();
            loop {
                std::thread::sleep(Duration::from_secs(2));
                let Some(runtime) = runtime.upgrade() else {
                    break;
                };
                // Exited shells whose GUI has detached no longer need a PTY,
                // history or attachments. Keep bookkeeping bounded as tabs churn.
                {
                    let _guard = runtime.host_operations.lock().unwrap();
                    let mut live = runtime.sessions.lock().unwrap();
                    live.retain(|id, session| {
                        if !session.finished_and_detached() {
                            return true;
                        }
                        crate::images::remove(&runtime.directory, *id);
                        let _ = fs::remove_file(runtime.directory.join(format!("{id}.json")));
                        false
                    });
                    versions.retain(|id, _| live.contains_key(id));
                }
                let sessions = runtime
                    .sessions
                    .lock()
                    .unwrap()
                    .values()
                    .cloned()
                    .collect::<Vec<_>>();
                for session in sessions {
                    let info = session.info();
                    let version = (
                        info.sequence,
                        info.directory.clone(),
                        info.size.columns,
                        info.size.rows,
                    );
                    if versions.get(&info.key.session) == Some(&version) {
                        continue;
                    }
                    let (info, history) = session.recovery();
                    let record = Recovery {
                        directory: info.directory,
                        size: info.size,
                        history: STANDARD.encode(history),
                    };
                    let live = runtime.sessions.lock().unwrap();
                    if !live.contains_key(&info.key.session) {
                        continue;
                    }
                    let path = runtime.directory.join(format!("{}.json", info.key.session));
                    // Atomic replacement means a killed daemon leaves either
                    // the previous complete history or the new complete history.
                    let temporary = path.with_extension("tmp");
                    if let Ok(bytes) = serde_json::to_vec(&record) {
                        if OpenOptions::new()
                            .write(true)
                            .create(true)
                            .truncate(true)
                            .mode(0o600)
                            .open(&temporary)
                            .and_then(|mut file| {
                                file.write_all(&bytes)?;
                                file.sync_all()
                            })
                            .is_ok()
                            && fs::rename(&temporary, &path).is_ok()
                        {
                            versions.insert(info.key.session, version);
                        }
                    }
                }
            }
        });
        for connection in endpoint.listener.incoming() {
            let stream = connection?;
            if self.clients.fetch_add(1, Ordering::AcqRel) >= MAX_CLIENTS {
                self.clients.fetch_sub(1, Ordering::AcqRel);
                continue;
            }
            let runtime = self.clone();
            std::thread::spawn(move || {
                let _ = runtime.connection(stream);
                runtime.clients.fetch_sub(1, Ordering::AcqRel);
            });
        }
        Ok(())
    }
    fn session(&self, key: &SessionKey) -> anyhow::Result<Arc<Session>> {
        anyhow::ensure!(key.host == self.host, "wrong host");
        anyhow::ensure!(
            key.instance == self.instance,
            "daemon restarted; original process is gone"
        );
        self.sessions
            .lock()
            .unwrap()
            .get(&key.session)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("unknown session"))
    }
    fn connection(&self, mut stream: UnixStream) -> anyhow::Result<()> {
        stream.set_read_timeout(Some(Duration::from_secs(10)))?;
        stream.set_write_timeout(Some(Duration::from_secs(5)))?;
        let (kind, bytes) = read_frame(&mut stream)?;
        anyhow::ensure!(kind == CONTROL, "expected hello");
        let Request::Hello { version } = serde_json::from_slice(&bytes)? else {
            anyhow::bail!("expected hello")
        };
        if version != VERSION {
            send(
                &mut stream,
                Event::Error {
                    code: "version_mismatch".into(),
                    message: "incompatible Kero protocol; no sessions changed".into(),
                },
            )?;
            return Ok(());
        }
        send(
            &mut stream,
            Event::Hello {
                version: VERSION,
                host: self.host,
                instance: self.instance,
                capabilities: vec![
                    "pty-stream-v1".into(),
                    "terminal-state-v1".into(),
                    "host-operations-v1".into(),
                    "cwd-events-v1".into(),
                    "ordered-checkpoint-v1".into(),
                    "terminal-colors-v1".into(),
                    "clipboard-image-v1".into(),
                ],
            },
        )?;
        stream.set_read_timeout(None)?;
        let client = Uuid::new_v4();
        let result = self.requests(&mut stream, client);
        // This is deliberately detach only, including EOF, SIGKILL of the GUI,
        // malformed frames, and an SSH bridge disappearing mid-request.
        for session in self.sessions.lock().unwrap().values() {
            session.detach(client);
        }
        let _ = stream.shutdown(Shutdown::Both);
        result
    }
    fn requests(&self, stream: &mut UnixStream, client: Uuid) -> anyhow::Result<()> {
        let mut attached: Option<Arc<Session>> = None;
        struct WatchGuard(Arc<AtomicBool>);
        impl Drop for WatchGuard {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let mut watching: Option<WatchGuard> = None;
        let writer = Arc::new(Mutex::new(stream.try_clone()?));
        loop {
            let (kind, bytes) = read_frame(stream)?;
            let result = (|| -> anyhow::Result<Option<Event>> {
                if kind == INPUT {
                    let session = attached
                        .as_ref()
                        .ok_or_else(|| anyhow::anyhow!("not attached"))?;
                    session.input(client, bytes)?;
                    return Ok(None);
                }
                anyhow::ensure!(kind == CONTROL, "unknown frame kind");
                match serde_json::from_slice::<Request>(&bytes)? {
                    Request::Hello { .. } => anyhow::bail!("already negotiated"),
                    Request::Watch { paths } => {
                        anyhow::ensure!(
                            attached.is_none() && watching.is_none(),
                            "watch requires a dedicated connection"
                        );
                        anyhow::ensure!(
                            !paths.is_empty() && paths.len() <= 64,
                            "watch requires 1 to 64 directories"
                        );
                        let directories = paths
                            .iter()
                            .map(|path| path.checked(self.host).map(std::path::Path::to_path_buf))
                            .collect::<anyhow::Result<Vec<_>>>()?;
                        let watch =
                            tty7_core::host::local::LocalHost::shared().watch(&directories)?;
                        send(&mut *writer.lock().unwrap(), Event::Watching)?;
                        let cancel = Arc::new(AtomicBool::new(false));
                        watching = Some(WatchGuard(cancel.clone()));
                        let output = writer.clone();
                        let close = stream.try_clone()?;
                        let host = self.host;
                        std::thread::spawn(move || {
                            while !cancel.load(Ordering::Acquire) {
                                match watch.events().try_recv() {
                                    Ok(paths) => {
                                        let event = Event::Changed {
                                            paths: paths
                                                .into_iter()
                                                .take(4096)
                                                .map(|path| crate::host::HostPath { host, path })
                                                .collect(),
                                        };
                                        let mut output = output.lock().unwrap();
                                        if cancel.load(Ordering::Acquire) {
                                            break;
                                        }
                                        if send(&mut output, event).is_err() {
                                            let _ = close.shutdown(Shutdown::Both);
                                            break;
                                        }
                                    }
                                    Err(_) => std::thread::sleep(Duration::from_millis(50)),
                                }
                            }
                            // Dropping WatchSub cancels the actual filesystem watch.
                        });
                        Ok(None)
                    }
                    Request::Create { mut launch } => {
                        let mut sessions = self.sessions.lock().unwrap();
                        anyhow::ensure!(
                            !sessions.contains_key(&launch.session),
                            "session ID already exists; attach explicitly"
                        );
                        anyhow::ensure!(sessions.len() < MAX_SESSIONS, "session limit reached");
                        let recovery =
                            File::open(self.directory.join(format!("{}.json", launch.session)))
                                .ok()
                                .and_then(|file| {
                                    let mut bytes = Vec::new();
                                    file.take(8 * 1024 * 1024 + 1)
                                        .read_to_end(&mut bytes)
                                        .ok()?;
                                    if bytes.len() > 8 * 1024 * 1024 {
                                        return None;
                                    }
                                    serde_json::from_slice::<Recovery>(&bytes).ok()
                                });
                        let mut history = launch
                            .history
                            .take()
                            .and_then(|text| STANDARD.decode(text).ok());
                        if let Some(saved) = recovery {
                            if Path::new(&saved.directory).is_dir() {
                                launch.directory = saved.directory;
                            }
                            // Persistent metadata never causes a previous task
                            // command to run again after a daemon/host restart.
                            launch.program = login_shell();
                            launch.arguments = vec!["-l".into()];
                            history = STANDARD.decode(saved.history).ok();
                        }
                        let session = Session::spawn_restored(
                            self.host,
                            self.instance,
                            launch,
                            history.as_deref(),
                        )?;
                        let info = session.info();
                        sessions.insert(info.key.session, session);
                        Ok(Some(Event::Created { session: info }))
                    }
                    Request::Attach { key } => {
                        anyhow::ensure!(
                            attached.is_none() && watching.is_none(),
                            "attach requires a dedicated connection"
                        );
                        let session = self.session(&key)?;
                        let rx = session.attach(client, stream.try_clone()?)?;
                        let output = writer.clone();
                        let close = stream.try_clone()?;
                        let owned_session = session.clone();
                        std::thread::spawn(move || {
                            while let Some(Frame(kind, bytes)) = rx.receive() {
                                if write_frame(&mut *output.lock().unwrap(), kind, &bytes).is_err()
                                {
                                    break;
                                }
                            }
                            owned_session.detach(client);
                            let _ = close.shutdown(Shutdown::Both);
                        });
                        attached = Some(session);
                        Ok(None)
                    }
                    Request::AttachSized { key, size } => {
                        anyhow::ensure!(
                            attached.is_none() && watching.is_none(),
                            "attach requires a dedicated connection"
                        );
                        let session = self.session(&key)?;
                        let rx = session.attach_sized(client, stream.try_clone()?, Some(size))?;
                        let output = writer.clone();
                        let close = stream.try_clone()?;
                        let owned_session = session.clone();
                        std::thread::spawn(move || {
                            while let Some(Frame(kind, bytes)) = rx.receive() {
                                if write_frame(&mut *output.lock().unwrap(), kind, &bytes).is_err()
                                {
                                    break;
                                }
                            }
                            owned_session.detach(client);
                            let _ = close.shutdown(Shutdown::Both);
                        });
                        attached = Some(session);
                        Ok(None)
                    }
                    Request::Colors {
                        key,
                        colors,
                        cursor_style,
                    } => {
                        self.session(&key)?.colors(client, colors, cursor_style)?;
                        Ok(None)
                    }
                    Request::Checkpoint { key } => {
                        self.session(&key)?.checkpoint(client)?;
                        Ok(None)
                    }
                    Request::Resize { key, size } => {
                        self.session(&key)?.resize(client, size)?;
                        Ok(None)
                    }
                    Request::Detach => {
                        // One subscription per socket: close after the ack so no
                        // queued output from its writer can leak into a new attach.
                        watching.take();
                        send(&mut *writer.lock().unwrap(), Event::Detached)?;
                        if let Some(session) = attached.take() {
                            session.detach(client);
                        }
                        return Err(anyhow::anyhow!("detached"));
                    }
                    Request::Terminate { key } => {
                        let _guard = self.host_operations.lock().unwrap();
                        self.session(&key)?.terminate()?;
                        self.sessions.lock().unwrap().remove(&key.session);
                        let _ =
                            fs::remove_file(self.directory.join(format!("{}.json", key.session)));
                        crate::images::remove(&self.directory, key.session);
                        Ok(Some(Event::Terminated))
                    }
                    Request::UploadImage { key, data } => {
                        anyhow::ensure!(
                            attached.is_none() && watching.is_none(),
                            "image upload requires a control connection"
                        );
                        let _guard = self.host_operations.lock().unwrap();
                        anyhow::ensure!(self.session(&key)?.info().alive, "session exited");
                        anyhow::ensure!(
                            data.len() <= (crate::images::MAX_IMAGE + 2) / 3 * 4,
                            "image exceeds the 4 MiB attachment limit"
                        );
                        let bytes = STANDARD.decode(data)?;
                        let path = crate::images::store(&self.directory, key.session, &bytes)?;
                        use sha2::Digest;
                        Ok(Some(Event::ImageUploaded {
                            path: path.to_string_lossy().into_owned(),
                            sha256: sha2::Sha256::digest(&bytes)
                                .iter()
                                .map(|b| format!("{b:02x}"))
                                .collect(),
                        }))
                    }
                    Request::Paste { key, text } => {
                        self.session(&key)?.paste(client, &text)?;
                        Ok(None)
                    }
                    Request::List => Ok(Some(Event::Sessions {
                        sessions: self
                            .sessions
                            .lock()
                            .unwrap()
                            .values()
                            .map(|s| s.info())
                            .collect(),
                    })),
                    Request::Host { request } => {
                        anyhow::ensure!(
                            attached.is_none() && watching.is_none(),
                            "host operations require a control connection"
                        );
                        let _guard = if matches!(
                            &request,
                            crate::host::HostRequest::Write { .. }
                                | crate::host::HostRequest::CreateFile { .. }
                                | crate::host::HostRequest::CreateDirectory { .. }
                                | crate::host::HostRequest::Rename { .. }
                                | crate::host::HostRequest::Remove { .. }
                        ) {
                            Some(self.host_operations.lock().unwrap())
                        } else {
                            None
                        };
                        Ok(Some(Event::Host {
                            response: crate::host::execute(self.host, request)?,
                        }))
                    }
                }
            })();
            match result {
                Ok(Some(event)) => send(&mut *writer.lock().unwrap(), event)?,
                Ok(None) => {}
                Err(error) if error.to_string() == "detached" => return Ok(()),
                Err(error) => send(
                    &mut *writer.lock().unwrap(),
                    Event::Error {
                        code: "request_failed".into(),
                        message: error.to_string(),
                    },
                )?,
            }
        }
    }
}
fn send(stream: &mut UnixStream, event: Event) -> anyhow::Result<()> {
    let Frame(kind, bytes) = Frame::event(event);
    Ok(write_frame(stream, kind, &bytes)?)
}
pub fn default_directory() -> anyhow::Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    Ok(PathBuf::from(home).join(".local/state/kero/daemon-v1"))
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Recovery {
    directory: String,
    size: Size,
    history: String,
}

fn login_shell() -> String {
    if let Ok(shell) = std::env::var("SHELL") {
        if shell.starts_with('/') && Path::new(&shell).is_file() {
            return shell;
        }
    }
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16 * 1024];
    let code = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut entry,
            buffer.as_mut_ptr() as *mut libc::c_char,
            buffer.len(),
            &mut result,
        )
    };
    if code == 0 && !result.is_null() && !entry.pw_shell.is_null() {
        if let Ok(shell) = unsafe { std::ffi::CStr::from_ptr(entry.pw_shell) }.to_str() {
            if shell.starts_with('/') {
                return shell.into();
            }
        }
    }
    "/bin/sh".into()
}
