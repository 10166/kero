package daemon

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	keroclient "kero/internal/client"
	"kero/internal/proto"
)

func leaseAttachment(t *testing.T, s *pane) *attachment {
	t.Helper()
	a := newAttachment(nil)
	if _, _, _, ok := s.attach(a); !ok {
		t.Fatal("attach failed")
	}
	t.Cleanup(func() { s.detach(a) })
	return a
}

func leaseEvent(t *testing.T, a *attachment, request string) proto.LeaseState {
	t.Helper()
	for {
		select {
		case frame := <-a.out:
			kind, payload, err := proto.ReadFrame(bufio.NewReader(bytes.NewReader(frame)))
			if err != nil {
				t.Fatal(err)
			}
			if kind != proto.FrameLease {
				continue
			}
			var state proto.LeaseState
			if err := json.Unmarshal(payload, &state); err != nil {
				t.Fatal(err)
			}
			if state.Request == request {
				return state
			}
		default:
			t.Fatalf("missing lease event for %q", request)
		}
	}
}

func TestExclusiveLeaseAndHostReclaim(t *testing.T) {
	s := testPane(t)
	host, controller, competitor := leaseAttachment(t, s), leaseAttachment(t, s), leaseAttachment(t, s)
	leaseEvent(t, host, "")
	leaseEvent(t, controller, "")
	leaseEvent(t, competitor, "")
	size := paneSize(t, s)
	s.ask(host, 90, 30, 9, 18)
	s.claim(host)
	s.leaseRequest(controller, proto.LeaseAcquire, true)
	if state := leaseEvent(t, controller, proto.LeaseAcquire); !state.Granted || !state.Held || !state.Owner {
		t.Fatalf("acquire: %+v", state)
	}
	s.ask(controller, 110, 40, 9, 18)
	size("controller size", 110, 40)
	s.leaseRequest(competitor, proto.LeaseAcquire, true)
	if state := leaseEvent(t, competitor, proto.LeaseAcquire); state.Granted || !state.Held || state.Owner {
		t.Fatalf("competing acquire: %+v", state)
	}
	if s.inputFrom(host, []byte("local")) || s.input([]byte("rpc")) || !s.inputFrom(controller, []byte("remote")) {
		t.Fatal("input was not restricted to controller")
	}
	s.ask(host, 80, 25, 9, 18)
	s.claim(host)
	size("host cannot resize", 110, 40)
	s.leaseRequest(host, proto.LeaseReclaim, true)
	if state := leaseEvent(t, host, proto.LeaseReclaim); !state.Granted || state.Held {
		t.Fatalf("host reclaim: %+v", state)
	}
	if state := leaseEvent(t, controller, ""); state.Held || state.Owner {
		t.Fatalf("controller revocation: %+v", state)
	}
	if s.inputFrom(controller, []byte("stale")) {
		t.Fatal("reclaimed attachment accepted input")
	}
	s.leaseRequest(controller, proto.LeaseAcquire, true)
	if state := leaseEvent(t, controller, proto.LeaseAcquire); state.Granted {
		t.Fatal("reclaimed attachment reacquired control")
	}
	size("host size restored", 80, 25)
	if !s.inputFrom(host, []byte("local")) {
		t.Fatal("host input did not resume")
	}
}

func TestLeaseDisconnectAndAuthorization(t *testing.T) {
	s := testPane(t)
	host, controller, remote := leaseAttachment(t, s), leaseAttachment(t, s), leaseAttachment(t, s)
	size := paneSize(t, s)
	s.ask(host, 90, 30, 9, 18)
	s.claim(host)
	s.leaseRequest(remote, proto.LeaseAcquire, false)
	if state := leaseEvent(t, remote, proto.LeaseAcquire); !state.Granted || !state.Owner {
		t.Fatalf("authenticated remote acquire: %+v", state)
	}
	s.leaseRequest(remote, proto.LeaseRelease, false)
	s.leaseRequest(controller, proto.LeaseAcquire, true)
	s.ask(controller, 100, 35, 9, 18)
	s.leaseRequest(remote, proto.LeaseReclaim, false)
	if state := leaseEvent(t, remote, proto.LeaseReclaim); state.Granted || !state.Held {
		t.Fatalf("unauthorized reclaim: %+v", state)
	}
	if s.inputFrom(host, []byte("local")) {
		t.Fatal("host input accepted while leased")
	}
	s.detach(controller)
	size("host restored after disconnect", 90, 30)
	if !s.inputFrom(host, []byte("local")) {
		t.Fatal("host input did not resume after disconnect")
	}
	remote = leaseAttachment(t, s)
	s.leaseRequest(remote, proto.LeaseAcquire, false)
	if state := leaseEvent(t, remote, proto.LeaseAcquire); !state.Granted || !state.Owner {
		t.Fatalf("acquire after disconnect: %+v", state)
	}
}

func TestLeaseSnapshotAtControllerSize(t *testing.T) {
	s := testPane(t)
	host, controller := leaseAttachment(t, s), leaseAttachment(t, s)
	s.leaseRequest(controller, proto.LeaseAcquire, true)
	s.ask(controller, 103, 37, 9, 18)
	s.output([]byte("snapshot text"))
	s.snapshot(controller)
	var snapshot proto.Snapshot
	for {
		select {
		case frame := <-controller.out:
			kind, payload, err := proto.ReadFrame(bufio.NewReader(bytes.NewReader(frame)))
			if err != nil {
				t.Fatal(err)
			}
			if kind != proto.FrameSnapshot {
				continue
			}
			var ok bool
			snapshot, ok = proto.ParseSnapshot(payload)
			if !ok {
				t.Fatal("invalid snapshot")
			}
			goto received
		default:
			t.Fatal("missing snapshot")
		}
	}
received:
	if snapshot.Error != "" || snapshot.Cols != 103 || snapshot.Rows != 37 || !bytes.Contains(snapshot.Data, []byte("snapshot text")) {
		t.Fatalf("snapshot: %dx%d, %q, error %q", snapshot.Cols, snapshot.Rows, snapshot.Data, snapshot.Error)
	}
	s.leaseRequest(host, proto.LeaseReclaim, true)
	s.snapshot(controller)
	for {
		select {
		case frame := <-controller.out:
			kind, payload, err := proto.ReadFrame(bufio.NewReader(bytes.NewReader(frame)))
			if err != nil {
				t.Fatal(err)
			}
			if kind == proto.FrameSnapshot {
				state, ok := proto.ParseSnapshot(payload)
				if !ok || state.Error == "" {
					t.Fatal("revoked controller received a snapshot")
				}
				return
			}
		default:
			t.Fatal("missing rejected snapshot")
		}
	}
}

// blockedInput simulates a full PTY and records bytes once input resumes.
type blockedInput struct {
	mu      sync.Mutex
	started chan struct{}
	cancel  chan struct{}
	accept  bool
	written []byte
}

func (w *blockedInput) SetWriteDeadline(deadline time.Time) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if deadline.IsZero() {
		w.cancel = make(chan struct{})
	} else if w.cancel != nil {
		select {
		case <-w.cancel:
		default:
			close(w.cancel)
		}
	}
	return nil
}

func (w *blockedInput) Write(p []byte) (int, error) {
	w.mu.Lock()
	if w.accept {
		w.written = append(w.written, p...)
		w.mu.Unlock()
		return len(p), nil
	}
	cancel := w.cancel
	w.mu.Unlock()
	select {
	case w.started <- struct{}{}:
	default:
	}
	<-cancel
	return 0, io.ErrClosedPipe
}

func TestReclaimInterruptsBlockedControllerInput(t *testing.T) {
	s := testPane(t)
	host, controller := leaseAttachment(t, s), leaseAttachment(t, s)
	w := &blockedInput{started: make(chan struct{}, 1)}
	s.mu.Lock()
	s.terminalInput = w
	s.mu.Unlock()
	s.leaseRequest(controller, proto.LeaseAcquire, false)
	result := make(chan bool, 1)
	go func() { result <- s.inputFrom(controller, bytes.Repeat([]byte("x"), 8192)) }()
	select {
	case <-w.started:
	case <-time.After(time.Second):
		t.Fatal("controller input did not block")
	}
	reclaimed := make(chan struct{})
	go func() { s.leaseRequest(host, proto.LeaseReclaim, true); close(reclaimed) }()
	select {
	case <-reclaimed:
	case <-time.After(time.Second):
		t.Fatal("reclaim waited for blocked input")
	}
	select {
	case ok := <-result:
		if ok {
			t.Fatal("cancelled input reported success")
		}
	case <-time.After(time.Second):
		t.Fatal("blocked input was not interrupted")
	}
	w.mu.Lock()
	w.accept = true
	w.mu.Unlock()
	if s.inputFrom(controller, []byte("stale")) || !s.inputFrom(host, []byte("host")) {
		t.Fatal("ownership after reclaim is incorrect")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if string(w.written) != "host" {
		t.Fatalf("input after reclaim = %q", w.written)
	}
}

func TestDisconnectInterruptsBlockedControllerInput(t *testing.T) {
	s := testPane(t)
	host, controller := leaseAttachment(t, s), leaseAttachment(t, s)
	w := &blockedInput{started: make(chan struct{}, 1)}
	s.mu.Lock()
	s.terminalInput = w
	s.mu.Unlock()
	s.leaseRequest(controller, proto.LeaseAcquire, false)
	result := make(chan bool, 1)
	go func() { result <- s.inputFrom(controller, bytes.Repeat([]byte("x"), 8192)) }()
	select {
	case <-w.started:
	case <-time.After(time.Second):
		t.Fatal("controller input did not block")
	}
	s.detach(controller)
	select {
	case ok := <-result:
		if ok {
			t.Fatal("disconnected input reported success")
		}
	case <-time.After(time.Second):
		t.Fatal("disconnect did not interrupt input")
	}
	w.mu.Lock()
	w.accept = true
	w.mu.Unlock()
	if !s.inputFrom(host, []byte("host")) {
		t.Fatal("host input did not resume")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if string(w.written) != "host" {
		t.Fatalf("input after disconnect = %q", w.written)
	}
}

type remoteLeaseDialer struct{ d *Daemon }

func (d remoteLeaseDialer) Dial() (net.Conn, error) {
	client, server := net.Pipe()
	go d.d.serve(server, identity{peer: "authenticated@example.com", via: "tailnet"})
	return client, nil
}

func TestRemoteCredentialRevokesBufferedControllerInput(t *testing.T) {
	s := testPane(t)
	s.d.panes = map[string]*pane{s.info.ID: s}
	s.d.clients = map[*proto.ClientInfo]struct{}{}
	dialer := remoteLeaseDialer{s.d}
	w := &blockedInput{started: make(chan struct{}, 1)}
	s.mu.Lock()
	s.terminalInput = w
	s.mu.Unlock()
	stream, err := keroclient.AttachVia(dialer, s.info.ID)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stream.Close() })
	states := make(chan proto.LeaseState, 16)
	stream.OnLeaseState = func(state proto.LeaseState) { states <- state }
	snapshots := make(chan proto.Snapshot, 1)
	stream.OnSnapshot = func(snapshot proto.Snapshot) { snapshots <- snapshot }
	go io.Copy(io.Discard, stream)
	control, err := keroclient.ConnectVia(dialer)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { control.Close() })
	if err := stream.AcquireLease(); err != nil {
		t.Fatal(err)
	}
	var token string
	for token == "" {
		select {
		case state := <-states:
			if state.Request == proto.LeaseAcquire {
				if !state.Granted || !state.Owner || state.Token == "" {
					t.Fatalf("acquire: %+v", state)
				}
				token = state.Token
			}
		case <-time.After(time.Second):
			t.Fatal("missing acquire response")
		}
	}
	if err := control.RevokeLease(s.info.ID, ""); err == nil {
		t.Fatal("empty credential accepted")
	}
	if err := control.RevokeLease(s.info.ID, token+"x"); err == nil {
		t.Fatal("guessed credential accepted")
	}
	if _, err := stream.Write(bytes.Repeat([]byte("x"), 8192)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-w.started:
	case <-time.After(time.Second):
		t.Fatal("controller input did not block")
	}
	if _, err := stream.Write([]byte("buffered")); err != nil {
		t.Fatal(err)
	}
	if err := control.RevokeLease(s.info.ID, token); err != nil {
		t.Fatal(err)
	}
	if err := control.RevokeLease(s.info.ID, token); err == nil {
		t.Fatal("replayed credential accepted")
	}
	// A later snapshot request is a barrier after the earlier input frames.
	if err := stream.RequestSnapshot(); err != nil {
		t.Fatal(err)
	}
	select {
	case snapshot := <-snapshots:
		if snapshot.Error == "" {
			t.Fatal("revoked controller received a snapshot")
		}
	case <-time.After(time.Second):
		t.Fatal("snapshot barrier timed out")
	}
	w.mu.Lock()
	w.accept = true
	w.mu.Unlock()
	if !s.input([]byte("host")) {
		t.Fatal("host input did not resume")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if string(w.written) != "host" {
		t.Fatalf("input after revocation = %q", w.written)
	}
}

func TestLeaseCredentialIsolationAndConcurrentRevocation(t *testing.T) {
	s := testPane(t)
	owner, observer := leaseAttachment(t, s), leaseAttachment(t, s)
	leaseEvent(t, owner, "")
	leaseEvent(t, observer, "")
	s.leaseRequest(owner, proto.LeaseAcquire, false)
	state := leaseEvent(t, owner, proto.LeaseAcquire)
	if !state.Granted || len(state.Token) < 40 {
		t.Fatalf("missing strong credential: %+v", state)
	}
	if seen := leaseEvent(t, observer, ""); seen.Token != "" || !seen.Held {
		t.Fatalf("observer state exposed credential: %+v", seen)
	}
	s.leaseRequest(observer, proto.LeaseAcquire, false)
	if denied := leaseEvent(t, observer, proto.LeaseAcquire); denied.Granted || denied.Token != "" {
		t.Fatalf("competitor obtained credential: %+v", denied)
	}
	wrong := []byte(state.Token)
	if wrong[0] == 'A' {
		wrong[0] = 'B'
	} else {
		wrong[0] = 'A'
	}
	if s.revokeLease(string(wrong)) || s.revokeLease("") {
		t.Fatal("incorrect credential revoked lease")
	}
	var wg sync.WaitGroup
	results := make(chan bool, 2)
	for range 2 {
		wg.Add(1)
		go func() { defer wg.Done(); results <- s.revokeLease(state.Token) }()
	}
	wg.Wait()
	close(results)
	successes := 0
	for success := range results {
		if success {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("%d revocations succeeded", successes)
	}
	size := paneSize(t, s)
	s.ask(observer, 90, 30, 9, 18)
	s.claim(observer)
	s.ask(owner, 130, 50, 9, 18)
	s.claim(owner)
	size("revoked owner cannot resize", 90, 30)
	if s.inputFrom(owner, []byte("buffered")) {
		t.Fatal("revoked owner accepted buffered input")
	}
}
