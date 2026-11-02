package remote

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func sshTestInstall() {
	mode := os.Getenv("KERO_TEST_INSTALL_SSH")
	args := strings.Join(os.Args[1:], " ")
	if mode == "batch" {
		if !strings.Contains(args, "BatchMode=yes") {
			os.Exit(2)
		}
		fmt.Print("installed")
		return
	}
	if !strings.Contains(args, "BatchMode=no") {
		os.Exit(3)
	}
	cmd := exec.Command(os.Getenv("SSH_ASKPASS"), "Password:")
	cmd.Env = append(os.Environ(), "KERO_TEST_INSTALL_SSH=")
	out, err := cmd.Output()
	if err != nil || string(out) != "install-secret\n" {
		os.Exit(4)
	}
	fmt.Print("installed")
}

func TestInstallInteractivePromptAndBatch(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("KERO_SSH", exe)
	a := Addr{Scheme: "ssh", Host: "install-test"}
	t.Setenv("KERO_TEST_INSTALL_SSH", "batch")
	out, err := InstallInteractive(context.Background(), a, "", nil)
	if err != nil || string(out) != "installed" {
		t.Fatalf("batch install: %q %v", out, err)
	}
	if !sshPeerSupported() {
		return
	}
	t.Setenv("KERO_TEST_INSTALL_SSH", "interactive")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err = InstallInteractive(ctx, a, "", func(ctx context.Context, c SSHChallenge) (SSHAnswer, error) {
		if c.Kind != SSHPassword {
			return SSHAnswer{}, fmt.Errorf("unexpected prompt")
		}
		return SSHAnswer{Text: "install-secret"}, nil
	})
	if err != nil || string(out) != "installed" {
		t.Fatalf("interactive install: %q %v", out, err)
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	_, err = InstallInteractive(cancelled, a, "", nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}
}
