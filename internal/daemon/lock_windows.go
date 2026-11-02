package daemon

import (
	"os"

	"golang.org/x/sys/windows"

	"kero/internal/proto"
)

// lockFile takes an exclusive lock of f, failing when another process has
// it.
func lockFile(f *os.File) error {
	var o windows.Overlapped
	return windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &o)
}

// notifyStop sends to ch when someone asks the daemon to stop: Windows
// has no signals for a process without a console, so the CLI sets an
// event of the daemon's (proto.StopEvent).
func notifyStop(ch chan<- os.Signal) {
	name, err := windows.UTF16PtrFromString(proto.StopEvent(os.Getpid()))
	if err != nil {
		return
	}
	ev, err := windows.CreateEvent(nil, 1, 0, name)
	if err != nil {
		return
	}
	go func() {
		windows.WaitForSingleObject(ev, windows.INFINITE)
		ch <- os.Interrupt
	}()
}
