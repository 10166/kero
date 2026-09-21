use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use tty7_core::host::local::LocalHost;
use uuid::Uuid;

const MAX_FILE: u64 = 4 * 1024 * 1024;

/// A path is never meaningful without its host, even when two hosts use the
/// same spelling. Validate that identity before touching the local filesystem.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostPath {
    pub host: Uuid,
    pub path: PathBuf,
}
impl HostPath {
    pub(crate) fn checked(&self, host: Uuid) -> anyhow::Result<&Path> {
        anyhow::ensure!(self.host == host, "path belongs to another host");
        anyhow::ensure!(self.path.is_absolute(), "host path must be absolute");
        Ok(&self.path)
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum HostRequest {
    ReadDirectory {
        path: HostPath,
    },
    Read {
        path: HostPath,
    },
    Write {
        path: HostPath,
        data: String,
        expected_sha256: String,
    },
    CreateFile {
        path: HostPath,
    },
    CreateDirectory {
        path: HostPath,
    },
    Rename {
        path: HostPath,
        destination: HostPath,
    },
    Remove {
        path: HostPath,
        recursive: bool,
    },
    Repository {
        path: HostPath,
    },
    Git {
        path: HostPath,
        arguments: Vec<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum HostResponse {
    Directory {
        entries: Vec<tty7_core::host::Entry>,
    },
    File {
        data: String,
        sha256: String,
    },
    Written {
        sha256: String,
    },
    Repository {
        path: Option<HostPath>,
    },
    Git {
        output: tty7_core::host::Output,
    },
    Done,
}

pub fn execute(host_id: Uuid, request: HostRequest) -> anyhow::Result<HostResponse> {
    let host = LocalHost::shared();
    Ok(match request {
        HostRequest::ReadDirectory { path } => {
            let mut entries = Vec::new();
            for entry in std::fs::read_dir(path.checked(host_id)?)? {
                anyhow::ensure!(entries.len() < 50_000, "directory has too many entries");
                let entry = entry?;
                let kind = entry.file_type()?;
                entries.push(tty7_core::host::Entry {
                    name: entry.file_name().to_string_lossy().into_owned(),
                    is_dir: kind.is_dir() || (kind.is_symlink() && entry.path().is_dir()),
                    is_symlink: kind.is_symlink(),
                    ignored: false,
                });
            }
            HostResponse::Directory { entries }
        }
        HostRequest::Read { path } => {
            let data = read_bounded(path.checked(host_id)?)?;
            HostResponse::File {
                sha256: digest(&data),
                data: STANDARD.encode(data),
            }
        }
        HostRequest::Write {
            path,
            data,
            expected_sha256,
        } => {
            let path = path.checked(host_id)?;
            let data = STANDARD.decode(data)?;
            anyhow::ensure!(data.len() as u64 <= MAX_FILE, "file too large");
            let old = read_bounded(path)?;
            anyhow::ensure!(
                digest(&old) == expected_sha256,
                "file changed since read; reload before saving"
            );
            atomic_save(path, &data, &expected_sha256)?;
            HostResponse::Written {
                sha256: digest(&data),
            }
        }
        HostRequest::CreateFile { path } => {
            host.create_file_new(path.checked(host_id)?)?;
            HostResponse::Done
        }
        HostRequest::CreateDirectory { path } => {
            host.create_dir(path.checked(host_id)?, false)?;
            HostResponse::Done
        }
        HostRequest::Rename { path, destination } => {
            host.rename(path.checked(host_id)?, destination.checked(host_id)?)?;
            HostResponse::Done
        }
        HostRequest::Remove { path, recursive } => {
            host.remove(path.checked(host_id)?, recursive)?;
            HostResponse::Done
        }
        HostRequest::Repository { path } => HostResponse::Repository {
            path: host
                .repo_root(path.checked(host_id)?)?
                .map(|path| HostPath {
                    host: host_id,
                    path,
                }),
        },
        HostRequest::Git { path, arguments } => {
            anyhow::ensure!(arguments.len() <= 256, "too many git arguments");
            HostResponse::Git {
                output: bounded_git(path.checked(host_id)?, &arguments)?,
            }
        }
    })
}
fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn read_bounded(path: &Path) -> anyhow::Result<Vec<u8>> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    anyhow::ensure!(
        std::fs::metadata(path)?.is_file(),
        "only regular files can be edited"
    );
    // A path replaced with a FIFO between stat and open must not park the
    // entire host-operation queue waiting for a writer.
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)?;
    anyhow::ensure!(
        file.metadata()?.is_file(),
        "only regular files can be edited"
    );
    let mut bytes = Vec::new();
    file.take(MAX_FILE + 1).read_to_end(&mut bytes)?;
    anyhow::ensure!(bytes.len() as u64 <= MAX_FILE, "file exceeds editor limit");
    Ok(bytes)
}

fn atomic_save(path: &Path, bytes: &[u8], expected: &str) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let path = std::fs::canonicalize(path)?;
    let metadata = std::fs::metadata(&path)?;
    anyhow::ensure!(
        metadata.is_file() && !metadata.permissions().readonly(),
        "file is not writable"
    );
    let temporary = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("file has no parent"))?
        .join(format!(".kero-save-{}", Uuid::new_v4()));
    struct Temporary(std::path::PathBuf);
    impl Drop for Temporary {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }
    let cleanup = Temporary(temporary);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&cleanup.0)?;
    file.write_all(bytes)?;
    file.set_permissions(metadata.permissions())?;
    file.sync_all()?;
    anyhow::ensure!(
        digest(&read_bounded(&path)?) == expected,
        "file changed during save; reload before saving"
    );
    std::fs::rename(&cleanup.0, &path)?;
    Ok(())
}

/// Pipe readers always drain, but retain bounded bytes. A timeout or overflow
/// kills this command's process group and returns an indeterminate result; the
/// GUI never automatically repeats a potentially mutating Git command.
fn bounded_git(path: &Path, arguments: &[String]) -> anyhow::Result<tty7_core::host::Output> {
    use std::os::unix::process::CommandExt;
    use std::{
        io::Read,
        process::{Command, Stdio},
        sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        },
        time::{Duration, Instant},
    };
    let mut command = Command::new("git");
    command
        .args(arguments)
        .current_dir(path)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn()?;
    let pid = child.id() as i32;
    let overflow = Arc::new(AtomicBool::new(false));
    fn reader(
        mut input: impl Read + std::os::fd::AsRawFd + Send + 'static,
        limit: usize,
        overflow: Arc<AtomicBool>,
    ) -> std::thread::JoinHandle<Vec<u8>> {
        unsafe {
            let fd = input.as_raw_fd();
            libc::fcntl(
                fd,
                libc::F_SETFL,
                libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK,
            );
        }
        std::thread::spawn(move || {
            let mut result = Vec::new();
            let mut chunk = [0u8; 16384];
            let deadline = Instant::now() + Duration::from_secs(60);
            loop {
                if overflow.load(Ordering::Acquire) || Instant::now() >= deadline {
                    overflow.store(true, Ordering::Release);
                    break;
                }
                match input.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(count) => {
                        let keep = count.min(limit - result.len());
                        result.extend_from_slice(&chunk[..keep]);
                        if keep < count {
                            overflow.store(true, Ordering::Release);
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5))
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(_) => {
                        overflow.store(true, Ordering::Release);
                        break;
                    }
                }
            }
            result
        })
    }
    let stdout = reader(
        child.stdout.take().unwrap(),
        4 * 1024 * 1024,
        overflow.clone(),
    );
    let stderr = reader(child.stderr.take().unwrap(), 256 * 1024, overflow.clone());
    let deadline = Instant::now() + Duration::from_secs(60);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if overflow.load(Ordering::Acquire) || Instant::now() >= deadline {
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            };
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let stdout = stdout.join().unwrap_or_default();
    let stderr = stderr.join().unwrap_or_default();
    if overflow.load(Ordering::Acquire) {
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
        }
    }
    anyhow::ensure!(
        !overflow.load(Ordering::Acquire),
        "Git output or duration exceeds the limit; operation result may be unknown"
    );
    anyhow::ensure!(
        status.is_some(),
        "Git timed out; operation result may be unknown"
    );
    Ok(tty7_core::host::Output {
        status: status.and_then(|s| s.code()),
        stdout,
        stderr,
    })
}
