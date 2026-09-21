use kero_daemon::{
    protocol::VERSION,
    runtime::{Endpoint, Runtime, default_directory},
};
use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    // Socket, lock, log and state files must never be exposed during creation.
    unsafe {
        libc::umask(0o077);
    }
    if std::env::args().nth(1).as_deref() == Some("--ssh-gateway") {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()?;
        let result = runtime.block_on(kero_daemon::gateway::run());
        runtime.shutdown_background();
        return result;
    }
    let mut directory = None;
    let mut serve = false;
    let mut bridge = false;
    let mut probe = false;
    let mut ensure = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--version" => {
                println!("kero-daemon {}", env!("CARGO_PKG_VERSION"));
                return Ok(());
            }
            "--protocol" => {
                println!(
                    "{}",
                    serde_json::json!({"product": "kero-daemon", "protocol": VERSION, "terminal_restore": true})
                );
                return Ok(());
            }
            "--state-dir" => {
                directory =
                    Some(PathBuf::from(args.next().ok_or_else(|| {
                        anyhow::anyhow!("missing --state-dir value")
                    })?))
            }
            "--ensure" => ensure = true,
            "--serve" => serve = true,
            "--stdio" => bridge = true,
            "--probe" => probe = true,
            _ => anyhow::bail!(
                "usage: kero-daemon (--serve | --stdio | --probe | --protocol | --version) [--state-dir PATH]"
            ),
        }
    }
    anyhow::ensure!(
        usize::from(serve) + usize::from(bridge) + usize::from(probe) + usize::from(ensure) == 1,
        "choose exactly one of --serve, --stdio or --probe"
    );
    let directory = directory.map(Ok).unwrap_or_else(default_directory)?;
    if ensure {
        use std::os::unix::process::CommandExt;
        if probe_daemon(&directory).is_ok() {
            return Ok(());
        }
        let mut command = std::process::Command::new(std::env::current_exe()?);
        command
            .args(["--serve", "--state-dir"])
            .arg(&directory)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = command.spawn()?;
        for _ in 0..100 {
            if probe_daemon(&directory).is_ok() {
                return Ok(());
            }
            if let Some(status) = child.try_wait()? {
                anyhow::ensure!(
                    status.success() || probe_daemon(&directory).is_ok(),
                    "daemon failed to start: {status}"
                );
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        anyhow::bail!("daemon did not become ready");
    }
    if probe {
        return probe_daemon(&directory);
    }
    if bridge {
        return stdio_bridge(&directory);
    }
    let endpoint = Endpoint::bind(&directory)?;
    // Do not use tty7's default paths or auto-installer. Its domain services
    // get a Kero-private config directory even when loaded headlessly.
    tty7_core::core::config::set_config_dir(directory.join("core"));
    Runtime::new(endpoint.host, directory).serve(endpoint)
}

fn stdio_bridge(directory: &std::path::Path) -> anyhow::Result<()> {
    use std::io::Write;
    use std::net::Shutdown;
    use std::os::unix::net::UnixStream;
    let mut output = UnixStream::connect(directory.join("daemon.sock"))?;
    let mut input = output.try_clone()?;
    let close = output.try_clone()?;
    std::thread::spawn(move || {
        let _ = std::io::copy(&mut std::io::stdin().lock(), &mut input);
        let _ = close.shutdown(Shutdown::Both);
    });
    let mut stdout = std::io::stdout().lock();
    let mut buffer = [0; 16 * 1024];
    loop {
        use std::io::Read;
        let count = output.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        stdout.write_all(&buffer[..count])?;
        stdout.flush()?;
    }
    Ok(())
}

fn probe_daemon(directory: &std::path::Path) -> anyhow::Result<()> {
    use kero_daemon::protocol::*;
    let mut stream = std::os::unix::net::UnixStream::connect(directory.join("daemon.sock"))?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(std::time::Duration::from_secs(2)))?;
    write_frame(
        &mut stream,
        CONTROL,
        &serde_json::to_vec(&Request::Hello { version: VERSION })?,
    )?;
    let (kind, data) = read_frame(&mut stream)?;
    anyhow::ensure!(kind == CONTROL, "invalid daemon handshake");
    match serde_json::from_slice::<Event>(&data)? {
        hello @ Event::Hello { .. } => println!("{}", serde_json::to_string(&hello)?),
        _ => anyhow::bail!("existing daemon is incompatible; active sessions were not interrupted"),
    }
    Ok(())
}
