use russh::keys::PublicKey;
use tty7_core::daemon::ssh::known_hosts::{
    HostKeyStatus, append_trusted_in_paths, check_paths, forget_superseded_paths,
};

const KEY_A: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPXO/kBX63iuiTczoR6uNdl3wAFK7tGWz70jCKkKlw5r";
const KEY_B: &str =
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEUVe8YNCi/DX61b+J6+ou0f0kCiuYE2/+p0qCIU6fN4";

fn key(value: &str) -> PublicKey {
    PublicKey::from_openssh(value).unwrap()
}

#[test]
fn known_hosts_files_are_checked_in_order_and_appended_to_the_first() {
    let directory = tempfile::tempdir().unwrap();
    let first = directory.path().join("first");
    let second = directory.path().join("second");
    std::fs::write(&second, format!("example.com {KEY_A}\n")).unwrap();

    assert_eq!(
        check_paths(
            &[first.clone(), second.clone()],
            "example.com",
            22,
            &key(KEY_A)
        ),
        HostKeyStatus::Known
    );

    append_trusted_in_paths(&[first.clone(), second], "example.com", 2222, &key(KEY_B)).unwrap();
    let first_contents = std::fs::read_to_string(&first).unwrap();
    assert!(first_contents.contains("[example.com]:2222"));
    assert!(first_contents.contains(KEY_B));
}

#[test]
fn a_changed_key_in_any_file_outranks_a_match_elsewhere() {
    let directory = tempfile::tempdir().unwrap();
    let first = directory.path().join("first");
    let second = directory.path().join("second");
    std::fs::write(&first, format!("example.com {KEY_A}\n")).unwrap();
    std::fs::write(&second, format!("example.com {KEY_B}\n")).unwrap();

    assert!(matches!(
        check_paths(&[first, second], "example.com", 22, &key(KEY_B)),
        HostKeyStatus::Changed { .. }
    ));
}

#[test]
fn superseding_removes_the_contradiction_from_every_listed_file() {
    let directory = tempfile::tempdir().unwrap();
    let first = directory.path().join("first");
    let second = directory.path().join("second");
    std::fs::write(&first, format!("example.com {KEY_A}\n")).unwrap();
    std::fs::write(&second, format!("example.com {KEY_A}\n")).unwrap();

    forget_superseded_paths(
        &[first.clone(), second.clone()],
        "example.com",
        22,
        &key(KEY_B),
    )
    .unwrap();
    append_trusted_in_paths(
        &[first.clone(), second.clone()],
        "example.com",
        22,
        &key(KEY_B),
    )
    .unwrap();

    assert_eq!(
        check_paths(&[first, second], "example.com", 22, &key(KEY_B)),
        HostKeyStatus::Known
    );
}
