//go:build !darwin && !linux

package remote

import (
	"errors"
	"net"
)

func sshPeerSupported() bool { return false }
func sshPeerCredentials(net.Conn) (int, int, error) {
	return 0, 0, errors.New("SSH peer identity unavailable")
}
func sshProcessInfo(int) (sshProcess, error) {
	return sshProcess{}, errors.New("SSH process identity unavailable")
}
