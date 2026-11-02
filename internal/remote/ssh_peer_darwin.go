//go:build darwin

package remote

import (
	"fmt"
	"net"
	"strings"
	"sync"

	"github.com/ebitengine/purego"
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
		pid, inner = unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		if inner != nil {
			return
		}
		var cred *unix.Xucred
		cred, inner = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if inner == nil {
			uid = int(cred.Uid)
		}
	})
	if err == nil {
		err = inner
	}
	return
}

var sshProcPath = sync.OnceValue(func() func(int32, *byte, uint32) int32 {
	lib, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		return nil
	}
	var fn func(int32, *byte, uint32) int32
	purego.RegisterLibFunc(&fn, lib, "proc_pidpath")
	return fn
})

func sshProcessInfo(pid int) (sshProcess, error) {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return sshProcess{}, err
	}
	if int(info.Proc.P_pid) != pid || info.Proc.P_stat == 0 || info.Proc.P_stat == 5 {
		return sshProcess{}, fmt.Errorf("process is not live")
	}
	fn := sshProcPath()
	if fn == nil {
		return sshProcess{}, fmt.Errorf("cannot inspect process executable")
	}
	var path [4096]byte
	n := fn(int32(pid), &path[0], uint32(len(path)))
	if n <= 0 || int(n) > len(path) {
		return sshProcess{}, fmt.Errorf("cannot inspect process executable")
	}
	return sshProcess{pid: pid, ppid: int(info.Eproc.Ppid), uid: int(info.Eproc.Ucred.Uid), start: fmt.Sprintf("%d.%d", info.Proc.P_starttime.Sec, info.Proc.P_starttime.Usec), exe: strings.TrimRight(string(path[:n]), "\x00")}, nil
}
