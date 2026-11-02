package daemon

import (
	"bytes"
	"encoding/binary"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
	"golang.org/x/sys/unix"
)

// procName returns the name of a process, as ps shows it.
func procName(pid int) string {
	kp, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return ""
	}
	b := kp.Proc.P_comm[:]
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	return string(b)
}

// procArgs returns the arguments a process was started with.
func procArgs(pid int) []string {
	buf, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil || len(buf) < 4 {
		return nil
	}
	argc := int(binary.LittleEndian.Uint32(buf))
	buf = buf[4:]
	// The executable's path, then NULs up to the arguments.
	i := bytes.IndexByte(buf, 0)
	if i < 0 {
		return nil
	}
	buf = buf[i:]
	for len(buf) > 0 && buf[0] == 0 {
		buf = buf[1:]
	}
	args := make([]string, 0, argc)
	for len(args) < argc && len(buf) > 0 {
		i := bytes.IndexByte(buf, 0)
		if i < 0 {
			args = append(args, string(buf))
			break
		}
		args = append(args, string(buf[:i]))
		buf = buf[i+1:]
	}
	return args
}

var (
	libprocOnce sync.Once
	procPidinfo func(pid int32, flavor int32, arg uint64, buffer unsafe.Pointer, size int32) int32
)

// procCwd returns the working directory of a process, through
// proc_pidinfo's PROC_PIDVNODEPATHINFO.
func procCwd(pid int) string {
	libprocOnce.Do(func() {
		lib, err := purego.Dlopen("/usr/lib/libSystem.B.dylib", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			return
		}
		purego.RegisterLibFunc(&procPidinfo, lib, "proc_pidinfo")
	})
	if procPidinfo == nil {
		return ""
	}
	// struct proc_vnodepathinfo: the current directory's vnode_info_path
	// (a vnode_info of 152 bytes, then the path of MAXPATHLEN), then the
	// root directory's.
	const vnodeInfo, maxPath = 152, 1024
	var buf [2 * (vnodeInfo + maxPath)]byte
	const pidVnodePathInfo = 9
	n := procPidinfo(int32(pid), pidVnodePathInfo, 0, unsafe.Pointer(&buf[0]), int32(len(buf)))
	if n <= 0 {
		return ""
	}
	path := buf[vnodeInfo : vnodeInfo+maxPath]
	if i := bytes.IndexByte(path, 0); i >= 0 {
		path = path[:i]
	}
	return string(path)
}

// procParent returns a process's parent, 0 when it is gone.
func procParent(pid int) int {
	kp, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil {
		return 0
	}
	return int(kp.Eproc.Ppid)
}
