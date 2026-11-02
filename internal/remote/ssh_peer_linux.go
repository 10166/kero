//go:build linux

package remote

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

func sshPeerSupported() bool { return true }

func sshPeerCredentials(c net.Conn) (pid, uid int, err error) {
	u, ok := c.(*net.UnixConn)
	if !ok {
		return 0, 0, fmt.Errorf("not a Unix socket")
	}
	raw, err := u.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var inner error
	err = raw.Control(func(fd uintptr) {
		var cred *unix.Ucred
		cred, inner = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		if inner == nil {
			pid, uid = int(cred.Pid), int(cred.Uid)
		}
	})
	if err == nil {
		err = inner
	}
	return
}

func sshProcessInfo(pid int) (sshProcess, error) {
	base := "/proc/" + strconv.Itoa(pid)
	data, err := os.ReadFile(base + "/stat")
	if err != nil {
		return sshProcess{}, err
	}
	end := strings.LastIndexByte(string(data), ')')
	if end < 0 {
		return sshProcess{}, fmt.Errorf("invalid process stat")
	}
	fields := strings.Fields(string(data[end+1:]))
	if len(fields) < 20 || fields[0] == "Z" || fields[0] == "X" {
		return sshProcess{}, fmt.Errorf("process is not live")
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return sshProcess{}, err
	}
	info, err := os.Stat(base)
	if err != nil {
		return sshProcess{}, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return sshProcess{}, fmt.Errorf("missing process owner")
	}
	// Stat the proc symlink itself later via os.Stat, so an executable renamed
	// after start still has the same inode as the trusted executable.
	return sshProcess{pid: pid, ppid: ppid, uid: int(stat.Uid), start: fields[19], exe: base + "/exe"}, nil
}
