package remote

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func TestSSHChallengeRouting(t *testing.T) {
	for _, tc := range []struct {
		message, mode string
		kind          SSHChallengeKind
		fingerprint   string
	}{
		{"Enter passphrase for key '/id':", "", SSHPassphrase, ""},
		{"alice@example's password:", "", SSHPassword, ""},
		{"Verification code:", "", SSHInteractive, ""},
		{"Touch your security key", "confirm", SSHConfirmation, ""},
		{"Waiting for touch", "none", SSHNotice, ""},
		{"ED25519 key fingerprint is SHA256:AbCd123+/\nAre you sure you want to continue connecting (yes/no/[fingerprint])?", "confirm", SSHHostKey, "SHA256:AbCd123+/"},
	} {
		c, err := sshChallenge(Addr{Host: "destination"}, askpassRequest{Message: tc.message, Mode: tc.mode})
		if err != nil || c.Kind != tc.kind || c.Fingerprint != tc.fingerprint || c.Address.Host != "destination" {
			t.Errorf("%q: %#v, %v", tc.message, c, err)
		}
	}
	if _, err := sshChallenge(Addr{}, askpassRequest{Message: "Are you sure you want to continue connecting?"}); err == nil {
		t.Error("accepted a host key without a fingerprint")
	}
}

func TestSSHHelperRoutesCredential(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix private socket")
	}
	s, err := newSSHAskpassServer(context.Background(), Addr{Host: "example"}, func(ctx context.Context, c SSHChallenge) (SSHAnswer, error) {
		if c.Kind != SSHPassphrase || c.Address.Host != "example" {
			return SSHAnswer{}, errors.New("wrong challenge")
		}
		return SSHAnswer{Text: "test secret"}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	c, server := net.Pipe()
	go s.serveRequest(server, func() bool { return true })
	defer c.Close()
	if err := json.NewEncoder(c).Encode(askpassRequest{Message: "Enter passphrase for key:"}); err != nil {
		t.Fatal(err)
	}
	var answer askpassResponse
	if err := json.NewDecoder(c).Decode(&answer); err != nil || !answer.OK || answer.Text != "test secret" {
		t.Fatalf("answer: %#v, %v", answer, err)
	}
	for _, value := range s.env() {
		if strings.Contains(value, "test secret") {
			t.Fatal("credential in environment")
		}
	}
}

func TestSSHHelperOwnershipAndCancellation(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix private socket")
	}
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan struct{})
	s, err := newSSHAskpassServer(ctx, Addr{Host: "example"}, func(ctx context.Context, c SSHChallenge) (SSHAnswer, error) {
		if c.Kind != SSHPassword {
			return SSHAnswer{}, errors.New("wrong challenge")
		}
		close(started)
		<-ctx.Done()
		return SSHAnswer{}, ctx.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	for _, name := range []string{s.dir, filepath.Join(s.dir, "askpass.sock"), s.config} {
		info, err := os.Stat(name)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0077 != 0 {
			t.Fatalf("%s is accessible to others: %v", name, info.Mode())
		}
	}
	c, server := net.Pipe()
	go s.serveRequest(server, func() bool { return true })
	defer c.Close()
	if err := json.NewEncoder(c).Encode(askpassRequest{Message: "Password:"}); err != nil {
		t.Fatal(err)
	}
	<-started
	cancel()
	var response askpassResponse
	if err := json.NewDecoder(c).Decode(&response); err == nil {
		t.Fatal("cancelled prompt returned an answer")
	}
	if !errors.Is(s.failure(), context.Canceled) {
		t.Fatalf("cancellation: %v", s.failure())
	}
	s.close()
	if _, err := os.Stat(s.dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("helper directory remains: %v", err)
	}
}

func TestSSHHelperRejectsUnrelatedSameUser(t *testing.T) {
	if !sshPeerSupported() {
		t.Skip("peer identity unavailable")
	}
	var prompts atomic.Int32
	s, err := newSSHAskpassServer(context.Background(), Addr{Host: "example"}, func(context.Context, SSHChallenge) (SSHAnswer, error) {
		prompts.Add(1)
		return SSHAnswer{Text: "secret"}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.close()
	root := exec.Command("sleep", "30")
	if err := root.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { root.Process.Kill(); root.Wait() }()
	if err := s.bind(root.Process.Pid); err != nil {
		t.Fatal(err)
	}
	c, err := net.Dial("unix", filepath.Join(s.dir, "askpass.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	_ = json.NewEncoder(c).Encode(askpassRequest{Message: "Password:"})
	var response askpassResponse
	if err := json.NewDecoder(c).Decode(&response); err == nil {
		t.Fatal("unrelated process received an answer")
	}
	if prompts.Load() != 0 {
		t.Fatal("unrelated process reached the prompt")
	}
}

// sshTestProxy is a network-free SSH server over the ProxyCommand pipes.
type sshTestPipe struct{}

func (sshTestPipe) Read(p []byte) (int, error)       { return os.Stdin.Read(p) }
func (sshTestPipe) Write(p []byte) (int, error)      { return os.Stdout.Write(p) }
func (sshTestPipe) Close() error                     { return nil }
func (sshTestPipe) LocalAddr() net.Addr              { return &net.UnixAddr{Name: "local", Net: "unix"} }
func (sshTestPipe) RemoteAddr() net.Addr             { return &net.UnixAddr{Name: "remote", Net: "unix"} }
func (sshTestPipe) SetDeadline(time.Time) error      { return nil }
func (sshTestPipe) SetReadDeadline(time.Time) error  { return nil }
func (sshTestPipe) SetWriteDeadline(time.Time) error { return nil }

func sshTestProxy() {
	b, err := os.ReadFile(os.Getenv("KERO_TEST_SSH_HOSTKEY"))
	if err != nil {
		return
	}
	signer, err := ssh.ParsePrivateKey(b)
	if err != nil {
		return
	}
	config := &ssh.ServerConfig{NoClientAuth: true}
	config.AddHostKey(signer)
	conn, channels, requests, err := ssh.NewServerConn(sshTestPipe{}, config)
	if err != nil {
		return
	}
	defer conn.Close()
	go ssh.DiscardRequests(requests)
	for ch := range channels {
		ch.Reject(ssh.Prohibited, "test complete")
	}
}

func sshTestKey(t *testing.T, name string) (string, ssh.PublicKey) {
	t.Helper()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	pub, err := ssh.NewPublicKey(private.Public())
	if err != nil {
		t.Fatal(err)
	}
	return path, pub
}

func TestOpenSSHHostKeyPolicyWithoutNetwork(t *testing.T) {
	if !sshPeerSupported() {
		t.Skip("peer identity unavailable")
	}
	sshPath, err := exec.LookPath("ssh")
	if err != nil {
		t.Skip("OpenSSH is unavailable")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	key, pub := sshTestKey(t, "hostkey")
	_, other := sshTestKey(t, "otherkey")
	for _, tc := range []struct {
		name, known string
		approve     bool
		wantPrompts int
		wantSaved   bool
	}{
		{"unknown-approved", "", true, 1, true},
		{"unknown-approved-wrapped", "", true, 1, true},
		{"unknown-rejected", "", false, 1, false},
		{"changed", "test.invalid " + string(ssh.MarshalAuthorizedKey(other)), true, 0, false},
		{"revoked", "@revoked test.invalid " + string(ssh.MarshalAuthorizedKey(pub)), true, 0, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			known := filepath.Join(t.TempDir(), "known_hosts")
			if err := os.WriteFile(known, []byte(tc.known), 0600); err != nil {
				t.Fatal(err)
			}
			var prompts atomic.Int32
			s, err := newSSHAskpassServer(context.Background(), Addr{Scheme: "ssh", Host: "test.invalid"}, func(ctx context.Context, c SSHChallenge) (SSHAnswer, error) {
				prompts.Add(1)
				if c.Kind != SSHHostKey || c.Fingerprint != ssh.FingerprintSHA256(pub) {
					return SSHAnswer{}, fmt.Errorf("unexpected host key challenge: %+v", c)
				}
				return SSHAnswer{Accept: tc.approve}, nil
			})
			if err != nil {
				t.Fatal(err)
			}
			defer s.close()
			proxy := "env KERO_TEST_SSH_PROXY=1 KERO_TEST_SSH_HOSTKEY=" + shellQuote(key) + " " + shellQuote(exe)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			program := sshPath
			if strings.HasSuffix(tc.name, "-wrapped") {
				program = filepath.Join(t.TempDir(), "ssh-wrapper")
				script := "#!/bin/sh\nsleep 1\nexec " + shellQuote(sshPath) + " \"$@\"\n"
				if err := os.WriteFile(program, []byte(script), 0700); err != nil { t.Fatal(err) }
			}
			cmd := exec.CommandContext(ctx, program, "-F", s.config, "-o", "UserKnownHostsFile="+known, "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ProxyCommand="+proxy, "-o", "NumberOfPasswordPrompts=0", "-T", "test.invalid", "true")
			cmd.Env = append(os.Environ(), s.env()...)
			var output bytes.Buffer
			cmd.Stdout, cmd.Stderr = &output, &output
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			if err := s.bind(cmd.Process.Pid); err != nil {
				cmd.Process.Kill()
				cmd.Wait()
				t.Fatal(err)
			}
			runErr := cmd.Wait()
			if ctx.Err() != nil {
				t.Fatal(ctx.Err())
			}
			if got := int(prompts.Load()); got != tc.wantPrompts {
				t.Fatalf("got %d prompts, want %d; helper error %v", got, tc.wantPrompts, s.failure())
			}
			if tc.name == "changed" && (runErr == nil || !strings.Contains(output.String(), "REMOTE HOST IDENTIFICATION HAS CHANGED")) {
				t.Fatalf("changed key was not rejected: %v %s", runErr, output.String())
			}
			if tc.name == "revoked" && (runErr == nil || !strings.Contains(output.String(), "REVOKED HOST KEY")) {
				t.Fatalf("revoked key was not rejected: %v %s", runErr, output.String())
			}
			contents, err := os.ReadFile(known)
			if err != nil {
				t.Fatal(err)
			}
			if tc.wantSaved && !strings.Contains(string(contents), strings.TrimSpace(string(ssh.MarshalAuthorizedKey(pub)))) {
				t.Fatal("accepted key was not persisted")
			}
			if !tc.wantSaved && string(contents) != tc.known {
				t.Fatalf("known_hosts changed: %q", contents)
			}
		})
	}
}

var _ io.ReadWriteCloser = sshTestPipe{}
