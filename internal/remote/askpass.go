package remote

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

// SSHChallenge describes a request from OpenSSH. Message is supplied by SSH;
// for a jump host it identifies that host even when Address is the destination.
type SSHChallenge struct {
	Kind        SSHChallengeKind
	Message     string
	Fingerprint string
	Address     Addr
}

type SSHChallengeKind string

const (
	SSHHostKey      SSHChallengeKind = "host-key"
	SSHPassword     SSHChallengeKind = "password"
	SSHPassphrase   SSHChallengeKind = "passphrase"
	SSHInteractive  SSHChallengeKind = "interactive"
	SSHConfirmation SSHChallengeKind = "confirmation"
	SSHNotice       SSHChallengeKind = "notice"
)

// SSHAnswer supplies Text for a secret or interactive question, or Accept for
// a host-key or other confirmation. Remember is reserved for the callback's
// own credential-store policy; this package never stores credentials.
type SSHAnswer struct {
	Text     string
	Accept   bool
	Remember bool
}

// SSHPrompt displays a challenge and returns the user's answer. A callback may
// consult a secure credential store and save only after explicit user consent.
// It must stop when ctx is cancelled and may be called concurrently.
type SSHPrompt func(ctx context.Context, challenge SSHChallenge) (SSHAnswer, error)

const askpassSocketEnv = "KERO_SSH_ASKPASS_SOCKET"

// IsSSHAskpass reports whether this process was invoked as an OpenSSH helper.
// Call it before parsing command-line arguments or starting the application.
func IsSSHAskpass() bool { return os.Getenv(askpassSocketEnv) != "" }

// RunSSHAskpass handles an OpenSSH helper invocation and returns its exit code.
// The caller must exit immediately with that code. It writes only the answer
// to stdout, as required by OpenSSH, and never prints errors or credentials.
func RunSSHAskpass() int {
	if len(os.Args) != 2 {
		return 1
	}
	conn, err := net.Dial("unix", os.Getenv(askpassSocketEnv))
	if err != nil {
		return 1
	}
	defer conn.Close()
	server, ok := sshAuthorizeServer(conn)
	if !ok {
		return 1
	}
	req := askpassRequest{Message: os.Args[1], Mode: os.Getenv("SSH_ASKPASS_PROMPT")}
	if json.NewEncoder(conn).Encode(req) != nil {
		return 1
	}
	var resp askpassResponse
	if json.NewDecoder(io.LimitReader(conn, 1<<20)).Decode(&resp) != nil || !resp.OK {
		return 1
	}
	again, ok := sshAuthorizeServer(conn)
	if !ok || again != server {
		return 1
	}
	if strings.ContainsAny(resp.Text, "\r\n\x00") {
		return 1
	}
	// Keep the listener alive until its identity has been rechecked. Darwin
	// may stop exposing peer credentials as soon as the other end closes.
	if _, err := conn.Write([]byte{1}); err != nil { return 1 }
	if _, err := fmt.Fprintln(os.Stdout, resp.Text); err != nil {
		return 1
	}
	return 0
}

type askpassRequest struct{ Message, Mode string }
type askpassResponse struct {
	Text string
	OK   bool
}

type sshAskpassServer struct {
	ctx         context.Context
	cancel      context.CancelFunc
	listener    net.Listener
	dir, config string
	address     Addr
	prompt      SSHPrompt
	mu          sync.Mutex
	err         error
	once        sync.Once
	rootReady   chan struct{}
	root        sshProcess
	rootErr     error
}

// OpenSSH recognizes SHA256 fingerprints in both normal and jump-host prompts.
var sshFingerprint = regexp.MustCompile(`SHA256:[A-Za-z0-9+/]+={0,2}`)

func newSSHAskpassServer(ctx context.Context, a Addr, prompt SSHPrompt) (*sshAskpassServer, error) {
	// Windows ACLs do not follow Unix directory permissions; never expose a
	// credential socket there until an ACL-protected transport is available.
	if runtime.GOOS == "windows" {
		return nil, errors.New("interactive SSH is not available on Windows")
	}
	if _, err := os.Executable(); err != nil {
		return nil, fmt.Errorf("locating SSH helper: %w", err)
	}
	tmp := ""
	if runtime.GOOS == "darwin" {
		tmp = "/tmp"
	} // keep Unix socket paths within Darwin's limit
	dir, err := os.MkdirTemp(tmp, "kero-ssh-")
	if err != nil {
		return nil, fmt.Errorf("creating SSH helper directory: %w", err)
	}
	cleanup := func(err error) (*sshAskpassServer, error) { os.RemoveAll(dir); return nil, err }
	if err := os.Chmod(dir, 0700); err != nil {
		return cleanup(err)
	}
	config := filepath.Join(dir, "config")
	// The same config is passed by OpenSSH to its ProxyJump subprocess. The
	// first values win, including for hosts in included user/system configs.
	const contents = "Host *\n    StrictHostKeyChecking ask\n    VerifyHostKeyDNS no\n    NoHostAuthenticationForLocalhost no\n    FingerprintHash sha256\n    ControlPath none\n    BatchMode no\n    Include ~/.ssh/config\n    Include /etc/ssh/ssh_config\n"
	if err := os.WriteFile(config, []byte(contents), 0600); err != nil {
		return cleanup(err)
	}
	ln, err := net.Listen("unix", filepath.Join(dir, "askpass.sock"))
	if err != nil {
		return cleanup(err)
	}
	if err := os.Chmod(filepath.Join(dir, "askpass.sock"), 0600); err != nil {
		ln.Close()
		return cleanup(err)
	}
	child, cancel := context.WithCancel(ctx)
	s := &sshAskpassServer{ctx: child, cancel: cancel, listener: ln, dir: dir, config: config, address: a, prompt: prompt, rootReady: make(chan struct{})}
	go s.serve()
	return s, nil
}

func (s *sshAskpassServer) env() []string {
	exe, _ := os.Executable()
	return []string{"SSH_ASKPASS=" + exe, "SSH_ASKPASS_REQUIRE=force", askpassSocketEnv + "=" + filepath.Join(s.dir, "askpass.sock")}
}

func (s *sshAskpassServer) serve() {
	for {
		c, err := s.listener.Accept()
		if err != nil {
			return
		}
		go s.handle(c)
	}
}

// bind records the actual SSH child before accepting its helper's requests.
func (s *sshAskpassServer) bind(pid int) error {
	s.root, s.rootErr = sshProcessInfo(pid)
	if s.rootErr == nil && (s.root.ppid != os.Getpid() || s.root.uid != os.Getuid()) {
		s.rootErr = errors.New("SSH process identity is invalid")
	}
	close(s.rootReady)
	return s.rootErr
}

func (s *sshAskpassServer) handle(c net.Conn) {
	defer c.Close()
	select {
	case <-s.rootReady:
	case <-s.ctx.Done():
		return
	}
	if s.rootErr != nil {
		return
	}
	peer, ok := sshAuthorizePeer(c, s.root)
	if !ok {
		return
	}
	s.serveRequest(c, func() bool {
		again, ok := sshAuthorizePeer(c, s.root)
		return ok && again == peer
	})
}

func (s *sshAskpassServer) serveRequest(c net.Conn, authorized func() bool) {
	defer c.Close()
	var req askpassRequest
	if json.NewDecoder(io.LimitReader(c, 64<<10)).Decode(&req) != nil {
		return
	}
	challenge, err := sshChallenge(s.address, req)
	if err != nil {
		s.setError(err)
		return
	}
	answer, err := s.prompt(s.ctx, challenge)
	if err != nil {
		s.setError(err)
		return
	}
	if err = s.ctx.Err(); err != nil {
		s.setError(err)
		return
	}
	if !authorized() {
		return
	}
	text := answer.Text
	if challenge.Kind == SSHHostKey || challenge.Kind == SSHConfirmation {
		if !answer.Accept {
			s.setError(ErrSSHRejected)
			return
		}
		text = "yes"
	}
	if strings.ContainsAny(text, "\r\n\x00") {
		s.setError(errors.New("SSH answer contains a line break"))
		return
	}
	if json.NewEncoder(c).Encode(askpassResponse{Text: text, OK: true}) != nil { return }
	// The helper acknowledges only after rechecking the server's identity.
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	var ack [1]byte
	_, _ = io.ReadFull(c, ack[:])
}

// ErrSSHRejected means the user declined an SSH confirmation.
var ErrSSHRejected = errors.New("SSH confirmation rejected")

func sshChallenge(a Addr, req askpassRequest) (SSHChallenge, error) {
	c := SSHChallenge{Address: a, Message: req.Message, Kind: SSHInteractive}
	lower := strings.ToLower(req.Message)
	switch {
	case strings.Contains(lower, "are you sure you want to continue connecting"):
		c.Kind = SSHHostKey
		c.Fingerprint = sshFingerprint.FindString(req.Message)
		if c.Fingerprint == "" {
			return c, errors.New("SSH host key prompt did not contain a SHA256 fingerprint")
		}
	case req.Mode == "confirm":
		c.Kind = SSHConfirmation
	case req.Mode == "none":
		c.Kind = SSHNotice
	case strings.Contains(lower, "passphrase"):
		c.Kind = SSHPassphrase
	case strings.Contains(lower, "password"):
		c.Kind = SSHPassword
	}
	return c, nil
}

func (s *sshAskpassServer) setError(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err == nil {
		s.err = err
	}
}
func (s *sshAskpassServer) failure() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}
func (s *sshAskpassServer) close() {
	s.once.Do(func() { s.cancel(); s.listener.Close(); os.RemoveAll(s.dir) })
}
