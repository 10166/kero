package relaybridge

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"kero/internal/relay"
)

var (
	ErrDisconnected = errors.New("relay bridge disconnected")
	ErrUnavailable  = errors.New("remote terminal unavailable")
	ErrBackpressure = errors.New("relay bridge output queue full")
)

const (
	maxQueuedFrames = 512
	maxQueuedBytes  = 8 << 20
	eventChunk      = 64 << 10
	eventBuffer     = 128
)

type socket interface {
	Read(context.Context) (relay.Message, error)
	WriteFrame(context.Context, []byte) error
	Ping(context.Context) error
	Close() error
}
type queuedFrame struct{ data []byte }
type peer struct {
	device   relay.Device
	online   bool
	epoch    string
	hello    hello
	topology *Topology
	retired  map[string]bool
}
type control struct {
	session, controller, stream, peerEpoch, localEpoch string
	lease                                              Lease
	ctx                                                context.Context
	cancel                                             context.CancelFunc
	commands                                           chan leaseCommand
}
type terminalKey struct{ host, session string }

// Service owns relay protocol state. Run it in a goroutine for the lifetime of
// the signed-in session; cancellation disconnects all remote terminals.
type Service struct {
	client      *relay.Client
	identity    *relay.Identity
	backend     Backend
	name        string
	cipher      *relay.Cipher
	mu          sync.Mutex
	state       string
	lastError   error
	running     bool
	hostEnabled bool
	epoch       string
	peers       map[string]*peer
	controls    map[string]*control
	terminals   map[terminalKey]*Terminal
	sock        socket
	cancel      context.CancelFunc
	out         chan queuedFrame
	queuedBytes int
	revision    uint64
	changes     chan struct{}
	queueSpace  chan struct{}
}

func New(client *relay.Client, identity *relay.Identity, backend Backend, name string) *Service {
	return &Service{client: client, identity: identity, backend: backend, name: name, cipher: relay.NewCipher(identity), peers: make(map[string]*peer), controls: make(map[string]*control), terminals: make(map[terminalKey]*Terminal), changes: make(chan struct{}, 1), queueSpace: make(chan struct{}, 1)}
}
func (s *Service) Changes() <-chan struct{} { return s.changes }

// State reports connecting, connected, failed, or stopped and the last error.
func (s *Service) State() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == "" {
		return "stopped", nil
	}
	return s.state, s.lastError
}
func (s *Service) setState(state string, err error) {
	s.mu.Lock()
	s.state = state
	s.lastError = err
	s.changed()
	s.mu.Unlock()
}
func (s *Service) changed() {
	select {
	case s.changes <- struct{}{}:
	default:
	}
}

// Hosts returns a detached snapshot safe for the caller to retain.
func (s *Service) Hosts() []Host {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]Host, 0, len(s.peers))
	for id, p := range s.peers {
		name := p.hello.Name
		if name == "" {
			name = "Kero Device"
		}
		var topology *Topology
		if p.topology != nil {
			data, _ := json.Marshal(p.topology)
			var copy Topology
			if json.Unmarshal(data, &copy) == nil {
				topology = &copy
			}
		}
		result = append(result, Host{ID: id, Name: name, Online: p.online, HostEnabled: p.online && p.hello.HostEnabled, Topology: topology})
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Name == result[j].Name {
			return result[i].ID < result[j].ID
		}
		return result[i].Name < result[j].Name
	})
	return result
}

// Run registers the device, refreshes the account device list and reconnects
// with bounded exponential backoff until ctx is cancelled.
func (s *Service) Run(ctx context.Context) error {
	if s.client == nil || s.identity == nil {
		return errors.New("relay bridge requires client and identity")
	}
	s.mu.Lock()
	if s.running {
		s.mu.Unlock()
		return errors.New("relay bridge already running")
	}
	s.running = true
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.running = false; s.mu.Unlock() }()
	delay := time.Second
	for ctx.Err() == nil {
		s.setState("connecting", nil)
		err := s.client.Register(ctx, s.identity)
		if err == nil {
			err = s.refreshDevices(ctx)
		}
		if err == nil {
			var conn *relay.Socket
			conn, err = s.client.Connect(ctx, s.identity)
			if err == nil {
				err = s.serve(ctx, conn)
				delay = time.Second
			}
		}
		if ctx.Err() != nil {
			break
		}
		s.setState("failed", err)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
		case <-timer.C:
		}
		if delay < 30*time.Second {
			delay *= 2
			if delay > 30*time.Second {
				delay = 30 * time.Second
			}
		}
	}
	s.setState("stopped", nil)
	return ctx.Err()
}
func (s *Service) refreshDevices(ctx context.Context) error {
	devices, err := s.client.Devices(ctx)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	seen := make(map[string]bool, len(devices))
	for _, d := range devices {
		d.ID = strings.ToLower(d.ID)
		if d.ID == strings.ToLower(s.identity.ID) || !validUUID(d.ID) {
			continue
		}
		seen[d.ID] = true
		p := s.peers[d.ID]
		if p == nil {
			p = &peer{retired: make(map[string]bool)}
			s.peers[d.ID] = p
		} else if p.device.AgreementKey != d.AgreementKey || p.device.SigningKey != d.SigningKey {
			s.clearPeerLocked(d.ID, p, true)
			p.retired = make(map[string]bool)
		}
		p.device = d
	}
	for id, p := range s.peers {
		if !seen[id] {
			s.clearPeerLocked(id, p, true)
			delete(s.peers, id)
		}
	}
	s.changed()
	return nil
}
func (s *Service) serve(parent context.Context, conn socket) error {
	epoch, err := newUUID()
	if err != nil {
		conn.Close()
		return err
	}
	ctx, cancel := context.WithCancel(parent)
	s.mu.Lock()
	s.sock = conn
	s.cancel = cancel
	s.epoch = epoch
	s.out = make(chan queuedFrame, maxQueuedFrames)
	s.queuedBytes = 0
	s.state = "connected"
	s.lastError = nil
	out := s.out
	s.changed()
	s.mu.Unlock()
	defer func() {
		cancel()
		s.mu.Lock()
		if s.sock == conn {
			s.disconnectLocked()
		}
		s.mu.Unlock()
		conn.Close()
	}()
	writeErr := make(chan error, 1)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case item := <-out:
				if err := conn.WriteFrame(ctx, item.data); err != nil {
					select {
					case writeErr <- err:
					default:
					}
					cancel()
					return
				}
				s.mu.Lock()
				if s.sock == conn {
					s.queuedBytes -= len(item.data)
					select {
					case s.queueSpace <- struct{}{}:
					default:
					}
				}
				s.mu.Unlock()
			}
		}
	}()
	go func() {
		ticker := time.NewTicker(25 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				pingCtx, stop := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Ping(pingCtx)
				stop()
				if err != nil {
					select {
					case writeErr <- err:
					default:
					}
					cancel()
					return
				}
			}
		}
	}()
	for {
		message, err := conn.Read(ctx)
		if err != nil {
			select {
			case e := <-writeErr:
				return e
			default:
				return err
			}
		}
		if message.Presence != nil {
			if err := s.refreshDevices(ctx); err != nil {
				return err
			}
			s.presence(message.Presence.OnlineDeviceIDs)
		} else if len(message.Frame) > 0 {
			s.receive(message.Frame)
		}
	}
}
func (s *Service) disconnectLocked() {
	if s.cancel != nil {
		s.cancel()
	}
	s.sock = nil
	s.cancel = nil
	s.out = nil
	s.queuedBytes = 0
	s.epoch = ""
	// Our socket's loss does not mean an online peer changed its epoch.
	for id, p := range s.peers {
		s.clearPeerLocked(id, p, false)
	}
	for _, c := range s.controls {
		releaseControl(c)
	}
	s.controls = make(map[string]*control)
	for _, t := range s.terminals {
		t.finishLocked("closed", ErrDisconnected)
	}
	s.terminals = make(map[terminalKey]*Terminal)
	s.changed()
}
func (s *Service) clearPeerLocked(id string, p *peer, retire bool) {
	if retire && p.epoch != "" {
		p.retired[p.epoch] = true
	}
	p.epoch = ""
	p.hello = hello{}
	p.topology = nil
	p.online = false
	for session, c := range s.controls {
		if c.controller == id {
			delete(s.controls, session)
			releaseControl(c)
		}
	}
	for key, t := range s.terminals {
		if key.host == id {
			delete(s.terminals, key)
			t.finishLocked("closed", ErrDisconnected)
		}
	}
}
func (s *Service) presence(ids []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	online := make(map[string]bool, len(ids))
	for _, id := range ids {
		online[strings.ToLower(id)] = true
	}
	for id, p := range s.peers {
		if !online[id] {
			if p.online {
				s.clearPeerLocked(id, p, true)
			}
			continue
		}
		if !p.online {
			p.online = true
		}
		s.sendJSONLocked(id, relay.KindHello, s.epoch, hello{s.name, s.hostEnabled})
	}
	s.changed()
}
func (s *Service) failLocked() {
	if s.cancel != nil {
		s.cancel()
	}
}
func (s *Service) sendLocked(id string, kind relay.FrameKind, stream string, data []byte) error {
	p := s.peers[id]
	if s.sock == nil || p == nil || !p.online {
		return ErrDisconnected
	}
	frame, err := s.cipher.Seal(data, kind, p.device, stream)
	if err != nil {
		return err
	}
	if len(s.out) >= maxQueuedFrames || s.queuedBytes+len(frame) > maxQueuedBytes {
		s.failLocked()
		return ErrBackpressure
	}
	s.queuedBytes += len(frame)
	s.out <- queuedFrame{frame}
	return nil
}
func (s *Service) sendJSONLocked(id string, kind relay.FrameKind, stream string, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return s.sendLocked(id, kind, stream, data)
}

// SetHostEnabled revokes active leases immediately when disabled.
func (s *Service) SetHostEnabled(enabled bool) {
	s.mu.Lock()
	if s.hostEnabled == enabled {
		s.mu.Unlock()
		return
	}
	s.hostEnabled = enabled
	for id, p := range s.peers {
		if p.online {
			s.sendJSONLocked(id, relay.KindHello, s.epoch, hello{s.name, enabled})
		}
	}
	if !enabled {
		for session := range s.controls {
			s.reclaimLocked(session)
		}
	}
	s.changed()
	s.mu.Unlock()
	if enabled {
		s.TopologyChanged()
	}
}

// TopologyChanged publishes a fresh snapshot to authenticated online peers.
func (s *Service) TopologyChanged() {
	if s.backend == nil {
		return
	}
	topology, err := s.backend.Topology()
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.hostEnabled || s.sock == nil {
		return
	}
	s.revision++
	topology.Revision = s.revision
	topology.HostName = s.name
	for id, p := range s.peers {
		if p.online && p.epoch != "" {
			s.sendJSONLocked(id, relay.KindTopology, s.epoch, topology)
		}
	}
}

// HasControl reports whether this relay service is handling a terminal lease.
func (s *Service) HasControl(sessionID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.controls[strings.ToLower(sessionID)] != nil
}

// Reclaim ends remote ownership when a local user takes back the terminal.
func (s *Service) Reclaim(sessionID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reclaimLocked(strings.ToLower(sessionID))
}
func (s *Service) reclaimLocked(session string) {
	if c := s.controls[session]; c != nil {
		delete(s.controls, session)
		s.sendJSONLocked(c.controller, relay.KindRelease, c.stream, sessionReference{session})
		releaseControl(c)
	}
}
func releaseControl(c *control) {
	if c.cancel != nil {
		c.cancel()
	}
	if c.commands != nil {
		close(c.commands)
		c.commands = nil
	}
	if c.lease != nil {
		go c.lease.Release()
	}
}

func validUUID(id string) bool {
	if len(id) != 36 || id[8] != '-' || id[13] != '-' || id[18] != '-' || id[23] != '-' {
		return false
	}
	b, err := hex.DecodeString(strings.ReplaceAll(id, "-", ""))
	return err == nil && len(b) == 16
}
func newUUID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	h := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s", h[:8], h[8:12], h[12:16], h[16:20], h[20:]), nil
}
