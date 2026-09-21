//! Private, bounded attachments. Paths refer to this host, never the GUI Mac.
use std::{fs, io::Write, os::unix::fs::OpenOptionsExt, path::Path, time::Duration};
use uuid::Uuid;
pub const MAX_IMAGE: usize = 4 * 1024 * 1024;
const SESSION_LIMIT: u64 = 64 * 1024 * 1024;
const TOTAL_LIMIT: u64 = 256 * 1024 * 1024;
pub fn store(root: &Path, session: Uuid, bytes: &[u8]) -> anyhow::Result<std::path::PathBuf> {
    anyhow::ensure!(
        bytes.len() <= MAX_IMAGE,
        "image exceeds the 4 MiB attachment limit"
    );
    anyhow::ensure!(
        bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "attachment must be a PNG image"
    );
    let root = root.join("images");
    fs::create_dir_all(&root)?;
    let mut total = 0;
    let mut session_total = 0;
    let mut count = 0;
    let mut session_count = 0;
    // A seven-day retention bound also covers cold sessions never reopened.
    for directory in fs::read_dir(&root)? {
        let directory = directory?;
        anyhow::ensure!(directory.file_type()?.is_dir(), "invalid image cache entry");
        for file in fs::read_dir(directory.path())? {
            let file = file?;
            anyhow::ensure!(file.file_type()?.is_file(), "invalid image cache file");
            let metadata = file.metadata()?;
            if metadata.modified()?.elapsed().unwrap_or_default() > Duration::from_secs(7 * 86400) {
                fs::remove_file(file.path())?;
                continue;
            }
            total += metadata.len();
            count += 1;
            if directory.file_name() == session.to_string().as_str() {
                session_total += metadata.len();
                session_count += 1;
            }
        }
        let _ = fs::remove_dir(directory.path());
    }
    anyhow::ensure!(
        count < 4096
            && session_count < 256
            && session_total + bytes.len() as u64 <= SESSION_LIMIT
            && total + bytes.len() as u64 <= TOTAL_LIMIT,
        "image cache is full; end unused terminal sessions before pasting more images"
    );
    let directory = root.join(session.to_string());
    fs::create_dir_all(&directory)?;
    let path = directory.join(format!("{}.png", Uuid::new_v4()));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)?;
    if let Err(error) = file.write_all(bytes).and_then(|_| file.sync_all()) {
        let _ = fs::remove_file(&path);
        return Err(error.into());
    }
    Ok(path)
}
pub fn remove(root: &Path, session: Uuid) {
    let _ = fs::remove_dir_all(root.join("images").join(session.to_string()));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cache_limits_and_expiry_are_enforced_without_deleting_recent_images() {
        let root = tempfile::tempdir().unwrap();
        let session = Uuid::new_v4();
        let image = b"\x89PNG\r\n\x1a\nfixture";
        let path = store(root.path(), session, image).unwrap();
        assert!(store(root.path(), session, b"not a PNG").is_err());
        let quota = path.parent().unwrap().join("quota.png");
        let file = fs::File::create(&quota).unwrap();
        file.set_len(SESSION_LIMIT).unwrap();
        assert!(store(root.path(), session, image).is_err());
        let old = std::time::SystemTime::now() - Duration::from_secs(8 * 86400);
        file.set_times(std::fs::FileTimes::new().set_modified(old))
            .unwrap();
        let next = store(root.path(), session, image).unwrap();
        assert!(path.exists() && next.exists() && !quota.exists());
        remove(root.path(), session);
        assert!(!path.exists() && !next.exists());
    }
}
