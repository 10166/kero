package remote

import (
	"net"
	"os"
	"os/exec"
)

// sshProcess is a kernel-derived identity; start distinguishes PID reuse.
type sshProcess struct {
	pid, ppid, uid int
	start          string
	exe            string
}

func sshSameExecutable(a, b string) bool {
	x, err := os.Stat(a)
	if err != nil {
		return false
	}
	y, err := os.Stat(b)
	return err == nil && os.SameFile(x, y)
}

// Executing a wrapper replaces its program without changing the process or
// its creation time. Compare process identity independently of executable.
func sshSameProcess(a, b sshProcess) bool {
	return a.pid == b.pid && a.ppid == b.ppid && a.uid == b.uid && a.start == b.start
}

// sshAuthorizePeer only accepts our own executable when launched by OpenSSH
// in this connection's still-live process tree. The immediate SSH parent is
// required, while intermediate shells used by ProxyJump are permitted.
func sshAuthorizePeer(c net.Conn, root sshProcess) (sshProcess, bool) {
	pid, uid, err := sshPeerCredentials(c)
	if err != nil || uid != os.Getuid() || pid <= 0 {
		return sshProcess{}, false
	}
	peer, err := sshProcessInfo(pid)
	if err != nil || peer.uid != uid {
		return sshProcess{}, false
	}
	exe, err := os.Executable()
	if err != nil || !sshSameExecutable(peer.exe, exe) {
		return sshProcess{}, false
	}
	parent, err := sshProcessInfo(peer.ppid)
	if err != nil || parent.uid != uid {
		return sshProcess{}, false
	}
	liveRoot, err := sshProcessInfo(root.pid)
	if err != nil || !sshSameProcess(liveRoot, root) || liveRoot.ppid != os.Getpid() {
		return sshProcess{}, false
	}
	standardSSH, _ := exec.LookPath("ssh")
	if !sshSameExecutable(parent.exe, liveRoot.exe) && (standardSSH == "" || !sshSameExecutable(parent.exe, standardSSH)) {
		return sshProcess{}, false
	}
	for range 64 {
		if parent.pid == root.pid {
			return peer, sshSameProcess(parent, root)
		}
		if parent.pid <= 1 || parent.ppid <= 1 {
			break
		}
		parent, err = sshProcessInfo(parent.ppid)
		if err != nil || parent.uid != uid {
			break
		}
	}
	return sshProcess{}, false
}

// The helper also authenticates the socket listener: a same-user process can
// otherwise replace the pathname and feed OpenSSH a forged "yes" answer.
func sshAuthorizeServer(c net.Conn) (sshProcess, bool) {
	pid, uid, err := sshPeerCredentials(c)
	if err != nil || uid != os.Getuid() {
		return sshProcess{}, false
	}
	server, err := sshProcessInfo(pid)
	if err != nil || server.uid != uid {
		return sshProcess{}, false
	}
	exe, err := os.Executable()
	if err != nil || !sshSameExecutable(server.exe, exe) {
		return sshProcess{}, false
	}
	child, err := sshProcessInfo(os.Getpid())
	if err != nil || child.uid != uid {
		return sshProcess{}, false
	}
	for range 64 {
		if child.ppid <= 1 {
			break
		}
		child, err = sshProcessInfo(child.ppid)
		if err != nil || child.uid != uid {
			break
		}
		if child.pid == server.pid {
			return server, child == server
		}
	}
	return sshProcess{}, false
}
