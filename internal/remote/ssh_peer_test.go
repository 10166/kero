package remote

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func sshTestForgedSocket() {
	ln, err := net.Listen("unix", os.Getenv("KERO_TEST_FORGED_SOCKET"))
	if err != nil {
		os.Exit(2)
	}
	defer ln.Close()
	fmt.Println("ready")
	c, err := ln.Accept()
	if err != nil {
		os.Exit(3)
	}
	defer c.Close()
	_, _ = io.Copy(io.Discard, c)
}

func TestSSHHelperRejectsForgedServer(t *testing.T) {
	if !sshPeerSupported() {
		t.Skip("peer identity unavailable")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	tmp := ""
	if runtime.GOOS == "darwin" {
		tmp = "/tmp"
	}
	dir, err := os.MkdirTemp(tmp, "kero-peer-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "socket")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	server := exec.CommandContext(ctx, exe)
	server.Env = append(os.Environ(), "KERO_TEST_FORGED_SOCKET="+path)
	stdout, err := server.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { server.Process.Kill(); server.Wait() }()
	if line, err := bufio.NewReader(stdout).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("server: %q %v", line, err)
	}
	helper := exec.CommandContext(ctx, exe, "Password:")
	helper.Env = append(os.Environ(), askpassSocketEnv+"="+path)
	out, err := helper.Output()
	if err == nil || len(out) != 0 {
		t.Fatalf("helper accepted forged server: %q %v", out, err)
	}
}
