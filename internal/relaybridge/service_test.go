package relaybridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"kero/internal/relay"
)

type memoryStore map[string][]byte

func (m memoryStore) Get(k string) ([]byte, error) {
	if v, ok := m[k]; ok {
		return v, nil
	}
	return nil, relay.ErrCredentialNotFound
}
func (m memoryStore) Set(k string, v []byte) error { m[k] = append([]byte(nil), v...); return nil }
func (m memoryStore) Delete(k string) error        { delete(m, k); return nil }

type fakeSocket struct{}

func (*fakeSocket) Read(ctx context.Context) (relay.Message, error) {
	<-ctx.Done()
	return relay.Message{}, ctx.Err()
}
func (*fakeSocket) WriteFrame(context.Context, []byte) error { return nil }
func (*fakeSocket) Ping(context.Context) error               { return nil }
func (*fakeSocket) Close() error                             { return nil }

type testLease struct {
	output   chan []byte
	released chan struct{}
	once     sync.Once
}

func (l *testLease) Output() <-chan []byte { return l.output }
func (l *testLease) Write([]byte) error    { return nil }
func (l *testLease) Resize(Resize) error   { return nil }
func (l *testLease) Release() error {
	l.once.Do(func() { close(l.released); close(l.output) })
	return nil
}

type testBackend struct {
	entered   chan struct{}
	permit    chan struct{}
	cancelled chan struct{}
	lease     *testLease
	bootstrap []byte
}

func (b *testBackend) Topology() (Topology, error) { return Topology{Projects: []Project{}}, nil }
func (b *testBackend) Acquire(ctx context.Context, _ string, _ Resize) (Lease, []byte, error) {
	b.entered <- struct{}{}
	select {
	case <-ctx.Done():
		close(b.cancelled)
		return nil, nil, ctx.Err()
	case <-b.permit:
		return b.lease, b.bootstrap, nil
	}
}

type testPeer struct {
	identity *relay.Identity
	cipher   *relay.Cipher
	epoch    string
}
type fixture struct {
	s       *Service
	backend *testBackend
	peers   []testPeer
	cancel  context.CancelFunc
}

func makeFixture(t *testing.T) *fixture {
	t.Helper()
	id, err := relay.LoadOrCreateIdentity(memoryStore{})
	if err != nil {
		t.Fatal(err)
	}
	lease := &testLease{output: make(chan []byte, 4), released: make(chan struct{})}
	b := &testBackend{entered: make(chan struct{}, 4), permit: make(chan struct{}), cancelled: make(chan struct{}), lease: lease, bootstrap: []byte("snapshot")}
	s := New(nil, id, b, "host")
	s.sock = &fakeSocket{}
	_, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.epoch = "00000000-0000-4000-8000-000000000001"
	s.out = make(chan queuedFrame, maxQueuedFrames)
	s.hostEnabled = true
	f := &fixture{s: s, backend: b, cancel: cancel}
	for _, epoch := range []string{"00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003"} {
		other, e := relay.LoadOrCreateIdentity(memoryStore{})
		if e != nil {
			t.Fatal(e)
		}
		p := testPeer{other, relay.NewCipher(other), epoch}
		f.peers = append(f.peers, p)
		s.peers[other.ID] = &peer{device: other.Record(), online: true, epoch: epoch, hello: hello{Name: "peer", HostEnabled: true}, retired: make(map[string]bool)}
	}
	t.Cleanup(func() { s.mu.Lock(); s.disconnectLocked(); s.mu.Unlock(); cancel() })
	return f
}
func (f *fixture) send(t *testing.T, peer int, kind relay.FrameKind, stream string, v any) {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	p := f.peers[peer]
	frame, err := p.cipher.Seal(data, kind, f.s.identity.Record(), stream)
	if err != nil {
		t.Fatal(err)
	}
	f.s.receive(frame)
}
func await(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for transition")
	}
}
func (f *fixture) next(t *testing.T, peer int) (relay.Frame, []byte) {
	t.Helper()
	select {
	case item := <-f.s.out:
		f.s.mu.Lock()
		f.s.queuedBytes -= len(item.data)
		f.s.mu.Unlock()
		frame, data, err := f.peers[peer].cipher.Open(item.data, f.s.identity.Record())
		if err != nil {
			t.Fatal(err)
		}
		return frame, data
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for frame")
		return relay.Frame{}, nil
	}
}

const session = "00000000-0000-4000-8000-000000000010"
const stream1 = "00000000-0000-4000-8000-000000000011"
const stream2 = "00000000-0000-4000-8000-000000000012"

func (f *fixture) attach(t *testing.T, p int, stream, hostEpoch string) {
	f.send(t, p, relay.KindAttach, stream, attachRequest{RequestID: stream, SessionID: session, ControllerEpoch: f.peers[p].epoch, HostEpoch: hostEpoch, Columns: 80, Rows: 24})
}

func TestCompetingLeasesAndStaleEpoch(t *testing.T) {
	f := makeFixture(t)
	f.attach(t, 0, stream1, "00000000-0000-4000-8000-000000000099")
	f.s.mu.Lock()
	n := len(f.s.controls)
	f.s.mu.Unlock()
	if n != 0 {
		t.Fatal("stale epoch acquired control")
	}
	f.attach(t, 0, stream1, f.s.epoch)
	await(t, f.backend.entered)
	f.attach(t, 1, stream2, f.s.epoch)
	frame, data := f.next(t, 1)
	if frame.Kind != relay.KindBusy {
		t.Fatalf("got %v, want busy", frame.Kind)
	}
	var response attachResponse
	if json.Unmarshal(data, &response) != nil || response.RequestID != stream2 || response.SessionID != session {
		t.Fatal("incorrect busy response")
	}
	f.s.Reclaim(session)
	await(t, f.backend.cancelled)
	frame, _ = f.next(t, 0)
	if frame.Kind != relay.KindRelease {
		t.Fatalf("got %v, want release", frame.Kind)
	}
}
func TestGrantBootstrapReclaimAndDisconnect(t *testing.T) {
	f := makeFixture(t)
	close(f.backend.permit)
	f.attach(t, 0, stream1, f.s.epoch)
	await(t, f.backend.entered)
	frame, _ := f.next(t, 0)
	if frame.Kind != relay.KindGranted {
		t.Fatalf("got %v, want granted", frame.Kind)
	}
	frame, data := f.next(t, 0)
	if frame.Kind != relay.KindBootstrap || string(data) != "snapshot" {
		t.Fatal("bootstrap not ordered after grant")
	}
	f.s.Reclaim(session)
	await(t, f.backend.lease.released)
	frame, _ = f.next(t, 0)
	if frame.Kind != relay.KindRelease {
		t.Fatal("reclaim did not notify peer")
	}
	// Disconnect releases an already granted lease as well as cancelling a
	// still-pending acquisition.
	g := makeFixture(t)
	close(g.backend.permit)
	g.attach(t, 0, stream1, g.s.epoch)
	await(t, g.backend.entered)
	g.next(t, 0)
	g.next(t, 0)
	g.s.mu.Lock()
	g.s.disconnectLocked()
	g.s.mu.Unlock()
	await(t, g.backend.lease.released)
	h := makeFixture(t)
	h.attach(t, 0, stream1, h.s.epoch)
	await(t, h.backend.entered)
	h.s.mu.Lock()
	h.s.disconnectLocked()
	h.s.mu.Unlock()
	await(t, h.backend.cancelled)
}
func TestBoundedOutputQueues(t *testing.T) {
	f := makeFixture(t)
	id := f.peers[0].identity.ID
	f.s.mu.Lock()
	var err error
	for range maxQueuedFrames + 1 {
		err = f.s.sendLocked(id, relay.KindOutput, stream1, []byte("x"))
		if err != nil {
			break
		}
	}
	if !errors.Is(err, ErrBackpressure) || len(f.s.out) != maxQueuedFrames {
		f.s.mu.Unlock()
		t.Fatalf("queue not bounded: %v", err)
	}
	f.s.mu.Unlock()
	tm := &Terminal{events: make(chan TerminalEvent, eventBuffer)}
	for range eventBuffer {
		if !tm.dataLocked("output", []byte("x")) {
			t.Fatal("premature event overflow")
		}
	}
	if tm.dataLocked("output", []byte("x")) {
		t.Fatal("event queue exceeded its limit")
	}
	tm.finishLocked("closed", ErrBackpressure)
	var last TerminalEvent
	for e := range tm.events {
		last = e
	}
	if last.State != "closed" || !errors.Is(last.Err, ErrBackpressure) {
		t.Fatal("overflow termination missing")
	}
}

func TestAuthenticatedTopologyRejectsReplayAndRetiredEpoch(t *testing.T) {
	f := makeFixture(t)
	f.s.hostEnabled = false
	peer := f.peers[0]
	newEpoch := "00000000-0000-4000-8000-000000000020"
	f.send(t, 0, relay.KindHello, newEpoch, hello{Name: "new", HostEnabled: true})
	f.next(t, 0) // hello acknowledgement
	old := Topology{Revision: 99, HostName: "stale", Projects: []Project{}}
	f.send(t, 0, relay.KindTopology, peer.epoch, old)
	f.send(t, 0, relay.KindHello, peer.epoch, hello{Name: "old", HostEnabled: true})
	f.s.mu.Lock()
	got := f.s.peers[peer.identity.ID]
	if got.epoch != newEpoch || got.topology != nil {
		f.s.mu.Unlock()
		t.Fatal("retired epoch changed peer state")
	}
	f.s.mu.Unlock()
	payload, err := json.Marshal(Topology{Revision: 1, HostName: "current", Projects: []Project{}})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := peer.cipher.Seal(payload, relay.KindTopology, f.s.identity.Record(), newEpoch)
	if err != nil {
		t.Fatal(err)
	}
	f.s.receive(frame)
	select {
	case <-f.s.Changes():
	default:
	}
	f.s.receive(frame)
	select {
	case <-f.s.Changes():
		t.Fatal("replayed frame notified observers")
	default:
	}
	f.s.mu.Lock()
	topology := f.s.peers[peer.identity.ID].topology
	f.s.mu.Unlock()
	if topology == nil || topology.Revision != 1 || topology.HostName != "current" {
		t.Fatal("authenticated topology not retained")
	}
}

func TestSwiftTopologyJSONShape(t *testing.T) {
	pane := PaneNode{Kind: "pane", Pane: &Pane{ID: session, Kind: "terminal", Title: "shell", SessionID: &sessionIDForTest}}
	split := PaneNode{Kind: "split", ID: stream1, Axis: "horizontal", First: &pane, Second: &pane}
	topology := Topology{HostName: "host", Projects: []Project{{ID: session, Name: "empty"}, {ID: stream1, Name: "split", Tabs: []Tab{{ID: stream2, Title: "tab", Layout: split, FocusedPaneID: session}}}}}
	encoded, err := json.Marshal(topology)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err = json.Unmarshal(encoded, &root); err != nil {
		t.Fatal(err)
	}
	projects := root["projects"].([]any)
	if _, ok := projects[0].(map[string]any)["tabs"].([]any); !ok {
		t.Fatal("empty tabs must be an array")
	}
	tab := projects[1].(map[string]any)["tabs"].([]any)[0].(map[string]any)
	node := tab["layout"].(map[string]any)
	if node["kind"] != "split" || node["axis"] != "horizontal" || node["id"] != stream1 || node["fraction"] != float64(0) {
		t.Fatal("split fields do not match Swift Codable")
	}
	for _, key := range []string{"first", "second"} {
		child := node[key].(map[string]any)
		descriptor := child["pane"].(map[string]any)
		if child["kind"] != "pane" || descriptor["kind"] != "terminal" || descriptor["sessionID"] != session {
			t.Fatal("pane fields do not match Swift Codable")
		}
		if _, exists := child["fraction"]; exists {
			t.Fatal("pane included split fields")
		}
	}
	empty, err := json.Marshal(Topology{})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(empty, []byte(`"projects":[]`)) {
		t.Fatalf("empty topology has no array: %s", empty)
	}
}

var sessionIDForTest = session

func TestSwiftBootstrapFramesRemainOrdered(t *testing.T) {
	f := makeFixture(t)
	f.backend.bootstrap = bytes.Repeat([]byte("checkpoint"), 120000)
	close(f.backend.permit)
	f.attach(t, 0, stream1, f.s.epoch)
	await(t, f.backend.entered)
	frame, _ := f.next(t, 0)
	if frame.Kind != relay.KindGranted {
		t.Fatal("missing grant")
	}
	var result []byte
	for index := range 3 {
		frame, part := f.next(t, 0)
		want := relay.KindOutput
		if index == 0 {
			want = relay.KindBootstrap
		}
		if frame.Kind != want || len(part) > 512<<10 {
			t.Fatal("incorrect bootstrap fragmentation")
		}
		result = append(result, part...)
	}
	if !bytes.Equal(result, f.backend.bootstrap) {
		t.Fatal("fragmented bootstrap changed bytes")
	}
}

func TestLocalReconnectAcceptsLiveSwiftPeerEpoch(t *testing.T) {
	f := makeFixture(t)
	f.s.hostEnabled = false
	peer := f.peers[0]
	payload, err := json.Marshal(hello{Name: "swift", HostEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	old, err := peer.cipher.Seal(payload, relay.KindHello, f.s.identity.Record(), peer.epoch)
	if err != nil {
		t.Fatal(err)
	}
	f.s.receive(old)
	f.s.mu.Lock()
	f.s.disconnectLocked()
	f.s.sock = &fakeSocket{}
	f.s.epoch = "00000000-0000-4000-8000-000000000030"
	f.s.out = make(chan queuedFrame, maxQueuedFrames)
	f.s.peers[peer.identity.ID].online = true
	f.s.mu.Unlock()
	f.s.receive(old)
	f.s.mu.Lock()
	epoch := f.s.peers[peer.identity.ID].epoch
	f.s.mu.Unlock()
	if epoch != "" {
		t.Fatal("accepted replayed hello")
	}
	fresh, err := peer.cipher.Seal(payload, relay.KindHello, f.s.identity.Record(), peer.epoch)
	if err != nil {
		t.Fatal(err)
	}
	f.s.receive(fresh)
	f.s.mu.Lock()
	epoch = f.s.peers[peer.identity.ID].epoch
	f.s.mu.Unlock()
	if epoch != peer.epoch {
		t.Fatal("rejected live peer's unchanged epoch")
	}
}
