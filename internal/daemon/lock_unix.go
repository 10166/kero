//go:build !windows

package daemon

import (
	"os"
	"syscall"
)

// lockFile takes an exclusive lock of f, failing when another process has
// it.
func lockFile(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
}

// notifyStop sends to ch when someone asks the daemon to stop, other than
// with a signal: on Unix, only signals do.
func notifyStop(ch chan<- os.Signal) {}
