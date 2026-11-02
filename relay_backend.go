package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"maps"
	"reflect"
	"sync"
	"time"

	"kero/internal/client"
	"kero/internal/proto"
	"kero/internal/relaybridge"
)

// relayBackend takes immutable snapshots on the UI thread; relay requests can
// then acquire terminals without reading the app's mutable state.
type relayBackend struct {
	identity string
	mu       sync.RWMutex
	topology relaybridge.Topology
	targets  map[string]relayTarget
}

type relayTarget struct {
	dialer client.Dialer
	pane   string
}

func relayUUID(identity, kind, id string) string {
	sum := sha256.Sum256([]byte(identity + "\x00" + kind + "\x00" + id))
	b := sum[:16]
	b[6] = b[6]&0x0f | 0x50
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func (b *relayBackend) Topology() (relaybridge.Topology, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.topology, nil
}

// refresh is called on the UI thread. A relay-exposed name is display metadata,
// not a path or a command line. Browser contents and URLs are never sent.
func (b *relayBackend) refresh(a *App) bool {
	topology := relaybridge.Topology{Projects: []relaybridge.Project{}}
	targets := make(map[string]relayTarget)
	for _, project := range a.st.Projects {
		h := a.hostOf(project.ID)
		if h.relayID != "" || h.conn != connReady {
			continue
		}
		key := h.name + "\x00" + project.ID
		p := relaybridge.Project{ID: relayUUID(b.identity, "project", key), Name: project.Name, Tabs: []relaybridge.Tab{}}
		for i := range a.st.Sessions {
			s := &a.st.Sessions[i]
			if s.Project != project.ID || a.hostOf(s.ID) != h || len(s.Panes) == 0 {
				continue
			}
			base := h.name + "\x00" + s.ID
			layout := s.Layout
			if layout == nil {
				layout = &proto.Layout{Pane: s.Panes[0].ID}
			}
			tabTargets := make(map[string]relayTarget)
			node, ok := b.node(h, s, layout, base, "", tabTargets)
			if !ok {
				continue
			}
			maps.Copy(targets, tabTargets)
			focus := s.Focus
			if s.PaneByID(focus) == nil {
				focus = s.Panes[0].ID
			}
			title := s.DisplayName(a.set.SessionName)
			if s.Name == "" {
				onlyBrowsers := true
				for i := range s.Panes {
					if !s.Panes[i].Browser() {
						onlyBrowsers = false
						break
					}
				}
				if onlyBrowsers {
					title = "Web pane"
				}
			}
			tab := relaybridge.Tab{ID: relayUUID(b.identity, "tab", base), Title: title, Layout: node, FocusedPaneID: relayUUID(b.identity, "pane", h.name+"\x00"+focus)}
			p.Tabs = append(p.Tabs, tab)
			if s.ID == a.selected {
				id := tab.ID
				p.SelectedTabID = &id
			}
		}
		if len(p.Tabs) != 0 {
			topology.Projects = append(topology.Projects, p)
		}
	}
	b.mu.Lock()
	changed := !reflect.DeepEqual(b.topology, topology)
	b.topology, b.targets = topology, targets
	b.mu.Unlock()
	return changed
}

func (b *relayBackend) node(h *host, s *proto.Session, l *proto.Layout, session, path string, targets map[string]relayTarget) (relaybridge.PaneNode, bool) {
	if l == nil {
		return relaybridge.PaneNode{}, false
	}
	if l.Leaf() {
		p := s.PaneByID(l.Pane)
		if p == nil {
			return relaybridge.PaneNode{}, false
		}
		key := h.name + "\x00" + p.ID
		title := p.PaneName()
		if p.Browser() {
			title = "Web pane"
		}
		pane := &relaybridge.Pane{ID: relayUUID(b.identity, "pane", key), Kind: "terminal", Title: title}
		if p.Browser() {
			pane.Kind = "browser"
		} else {
			id := relayUUID(b.identity, "terminal", key)
			pane.SessionID = &id
			targets[id] = relayTarget{dialer: h.dialer(), pane: p.ID}
		}
		return relaybridge.PaneNode{Kind: "pane", Pane: pane}, true
	}
	first, ok1 := b.node(h, s, l.A, session, path+"a", targets)
	second, ok2 := b.node(h, s, l.B, session, path+"b", targets)
	if !ok1 || !ok2 {
		return relaybridge.PaneNode{}, false
	}
	axis := "vertical"
	if l.Row {
		axis = "horizontal"
	}
	ratio := l.Ratio
	if ratio <= 0 || ratio >= 1 {
		ratio = 0.5
	}
	return relaybridge.PaneNode{Kind: "split", ID: relayUUID(b.identity, "split", session+"\x00"+path), Axis: axis, Fraction: ratio, First: &first, Second: &second}, true
}

func (b *relayBackend) Acquire(ctx context.Context, sessionID string, size relaybridge.Resize) (relaybridge.Lease, []byte, error) {
	b.mu.RLock()
	target, ok := b.targets[sessionID]
	b.mu.RUnlock()
	if !ok {
		return nil, nil, relaybridge.ErrUnavailable
	}
	type result struct {
		stream  *client.Stream
		control *client.Client
		err     error
	}
	ready := make(chan result)
	go func() {
		control, err := client.ConnectVia(target.dialer)
		var stream *client.Stream
		if err == nil && !control.Welcome.LeaseRevoke {
			err = errors.New("remote daemon must be updated to support safe control")
		}
		if err == nil {
			stream, err = client.AttachVia(target.dialer, target.pane)
		}
		if err != nil && control != nil {
			control.Close()
			control = nil
		}
		select {
		case ready <- result{stream, control, err}:
		case <-ctx.Done():
			if stream != nil {
				stream.Close()
			}
			if control != nil {
				control.Close()
			}
		}
	}()
	var stream *client.Stream
	var control *client.Client
	select {
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	case r := <-ready:
		if r.err != nil {
			return nil, nil, r.err
		}
		stream = r.stream
		control = r.control
	}
	lease := &daemonRelayLease{stream: stream, control: control, pane: target.pane, output: make(chan []byte, 64), done: make(chan struct{}), states: make(chan proto.LeaseState, 8), snapshots: make(chan proto.Snapshot, 1)}
	stream.OnLeaseState = lease.onState
	stream.OnSnapshot = lease.onSnapshot
	go lease.read()
	stop := context.AfterFunc(ctx, func() { lease.Release() })
	fail := func(err error) (relaybridge.Lease, []byte, error) { stop(); lease.Release(); return nil, nil, err }
	if err := stream.AcquireLease(); err != nil {
		return fail(err)
	}
	for {
		select {
		case <-ctx.Done():
			return fail(ctx.Err())
		case <-lease.done:
			return fail(relaybridge.ErrUnavailable)
		case state := <-lease.states:
			if state.Request != proto.LeaseAcquire {
				continue
			}
			if !state.Granted || !state.Owner {
				return fail(errors.New("terminal is already controlled"))
			}
			if state.Token == "" {
				return fail(errors.New("daemon did not provide a lease credential"))
			}
			lease.mu.Lock()
			lease.token = state.Token
			lease.mu.Unlock()
			goto acquired
		}
	}
acquired:
	if err := stream.ResizePixels(int(size.Columns), int(size.Rows), int(size.CellWidth), int(size.CellHeight)); err != nil {
		return fail(err)
	}
	if err := stream.RequestSnapshot(); err != nil {
		return fail(err)
	}
	select {
	case <-ctx.Done():
		return fail(ctx.Err())
	case <-lease.done:
		return fail(relaybridge.ErrUnavailable)
	case snapshot := <-lease.snapshots:
		if snapshot.Error != "" {
			return fail(errors.New(snapshot.Error))
		}
		return lease, snapshot.Data, nil
	}
}

type daemonRelayLease struct {
	stream    *client.Stream
	control   *client.Client
	pane      string
	mu        sync.Mutex
	token     string
	output    chan []byte
	done      chan struct{}
	states    chan proto.LeaseState
	snapshots chan proto.Snapshot
	once      sync.Once
	// Read callbacks and this flag are confined to the reader goroutine.
	owned, snapshot bool
}

func (l *daemonRelayLease) onState(state proto.LeaseState) {
	if l.owned && !state.Owner {
		l.Release()
	}
	l.owned = state.Owner
	select {
	case l.states <- state:
	default:
	}
}
func (l *daemonRelayLease) onSnapshot(snapshot proto.Snapshot) {
	l.snapshot = snapshot.Error == ""
	select {
	case l.snapshots <- snapshot:
	default:
	}
}
func (l *daemonRelayLease) read() {
	defer close(l.output)
	defer l.Release()
	buf := make([]byte, 32<<10)
	for {
		n, err := l.stream.Read(buf)
		if n > 0 && l.snapshot {
			data := append([]byte(nil), buf[:n]...)
			select {
			case l.output <- data:
			case <-l.done:
				return
			}
		}
		if err != nil {
			return
		}
	}
}
func (l *daemonRelayLease) Output() <-chan []byte   { return l.output }
func (l *daemonRelayLease) Write(data []byte) error { _, err := l.stream.Write(data); return err }
func (l *daemonRelayLease) Resize(size relaybridge.Resize) error {
	return l.stream.ResizePixels(int(size.Columns), int(size.Rows), int(size.CellWidth), int(size.CellHeight))
}
func (l *daemonRelayLease) Release() error {
	var err error
	l.once.Do(func() {
		close(l.done)
		l.mu.Lock()
		token := l.token
		l.mu.Unlock()
		if token != "" {
			result := make(chan error, 1)
			go func() { result <- l.control.RevokeLease(l.pane, token) }()
			timer := time.NewTimer(5 * time.Second)
			select {
			case err = <-result:
				timer.Stop()
			case <-timer.C:
				err = errors.New("timed out revoking the remote terminal lease")
			}
		}
		l.control.Close()
		if closeErr := l.stream.Close(); err == nil {
			err = closeErr
		}
	})
	return err
}

var _ relaybridge.Backend = (*relayBackend)(nil)
var _ relaybridge.Lease = (*daemonRelayLease)(nil)
