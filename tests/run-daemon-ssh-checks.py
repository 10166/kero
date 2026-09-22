#!/usr/bin/env python3
"""Exercise native SSH using a disposable loopback sshd, keys and known host.
No system Remote Login setting or user's SSH configuration is changed.
"""
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
cargo = shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo")
sshd = shutil.which("sshd") or "/usr/sbin/sshd"
with tempfile.TemporaryDirectory(prefix="kero-ssh-check-") as temporary:
    directory = Path(temporary)
    for name in ("host", "client"):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(directory / name)], check=True)
    (directory / "authorized_keys").write_text((directory / "client.pub").read_text())
    (directory / "authorized_keys").chmod(0o600)
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    user = pwd.getpwuid(os.getuid()).pw_name
    config = directory / "sshd_config"
    config.write_text(f"""ListenAddress 127.0.0.1
Port {port}
HostKey {directory}/host
PidFile {directory}/sshd.pid
AuthorizedKeysFile {directory}/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
AllowUsers {user}
LogLevel VERBOSE
""")
    fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(directory / "host.pub"), "-E", "sha256"], text=True).split()[1]
    (directory / "known_hosts").write_text(f"[127.0.0.1]:{port} {(directory / 'host.pub').read_text().strip()}\n")
    (directory / "known_hosts").chmod(0o600)
    fixture = directory / "fixture.json"
    fixture.write_text(json.dumps({"directory": str(directory), "port": port, "user": user, "fingerprint": fingerprint}))
    subprocess.run([sshd, "-t", "-f", str(config)], check=True)
    with (directory / "sshd.log").open("w+") as log:
        server = subprocess.Popen([sshd, "-D", "-e", "-f", str(config)], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                        break
                except OSError:
                    if server.poll() is not None or time.monotonic() >= deadline:
                        log.seek(0)
                        raise RuntimeError("isolated sshd failed:\n" + log.read())
                    time.sleep(0.05)
            environment = dict(os.environ, KERO_SSH_FIXTURE=str(fixture))
            result = subprocess.run([cargo, "test", "--locked", "--manifest-path", str(root / "daemon/Cargo.toml"), "--test", "native_ssh", "native_install_and_disconnect_preserve_remote_shell", "--", "--ignored", "--nocapture"], env=environment)
            if result.returncode:
                log.seek(0)
                print(log.read())
            raise SystemExit(result.returncode)
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
