package main

import (
	"errors"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/egoist/mygo/plugins/terminal"

	"kero/internal/proto"
	"kero/internal/relaybridge"
	"kero/locales"
)

type relayPaneTarget struct{ host, session string }

func (a *App) makeRelayBackend(identity string) relaybridge.Backend {
	b := &relayBackend{identity: identity}
	b.refresh(a)
	a.relayBackend = b
	return b
}

func (a *App) updateRelayTopology() {
	if a.relayBackend != nil && a.relayBackend.refresh(a) && a.relay.service != nil {
		a.relay.service.TopologyChanged()
	}
}

func relayObjectID(host, kind, id string) string { return "relay/" + host + "/" + kind + "/" + id }

// relayHostsChanged replaces only the relay's display metadata. No remote
// paths, browser URLs or commands are needed to render the shared layout.
func (a *App) relayHostsChanged(hosts []relaybridge.Host) {
	if len(a.hosts) == 0 {
		return
	}
	old := make(map[string]*host)
	keep := make([]*host, 0, len(a.hosts)+len(hosts))
	for _, h := range a.hosts {
		if h.relayID == "" {
			keep = append(keep, h)
		} else {
			old[h.relayID] = h
		}
	}
	targets := make(map[string]relayPaneTarget)
	states := make(map[*host]proto.State)
	for _, remote := range hosts {
		if !remote.Online || !remote.HostEnabled || remote.Topology == nil {
			continue
		}
		id := strings.ToLower(remote.ID)
		h := old[id]
		if h == nil {
			h = &host{relayID: id}
		}
		h.name, h.conn, h.loaded = remote.Name, connReady, true
		states[h] = relayWorkspace(id, *remote.Topology, targets)
		keep = append(keep, h)
		delete(old, id)
	}
	for _, h := range old {
		a.dropTerms(h)
	}
	for id, previous := range a.relayPanes {
		if next, ok := targets[id]; !ok || next != previous {
			a.dropTerm(id)
		}
	}
	a.relayPanes = targets
	localState := proto.State{Projects: a.projectsOf(a.local()), Sessions: a.sessionsOf(a.local())}
	a.hosts = keep
	a.mergeState(a.local(), localState)
	for h, state := range states {
		a.mergeState(h, state)
	}
	a.reselect()
	a.updateTitle()
}

func relayWorkspace(host string, topology relaybridge.Topology, targets map[string]relayPaneTarget) proto.State {
	var state proto.State
	for _, project := range topology.Projects {
		projectID := relayObjectID(host, "project", project.ID)
		p := proto.Project{ID: projectID, Name: project.Name}
		var sessions []proto.Session
		for _, tab := range project.Tabs {
			sessionID := relayObjectID(host, "tab", tab.ID)
			var panes []proto.Pane
			layout, ok := relayLayout(host, &tab.Layout, &panes, targets)
			if !ok || len(panes) == 0 {
				continue
			}
			focus := relayObjectID(host, "pane", tab.FocusedPaneID)
			s := proto.Session{ID: sessionID, Project: projectID, Name: tab.Title, Panes: panes, Layout: layout, Focus: focus}
			if s.PaneByID(focus) == nil {
				s.Focus = panes[0].ID
			}
			sessions = append(sessions, s)
		}
		if len(sessions) > 0 {
			state.Projects = append(state.Projects, p)
			state.Sessions = append(state.Sessions, sessions...)
		}
	}
	return state
}

func relayLayout(host string, node *relaybridge.PaneNode, panes *[]proto.Pane, targets map[string]relayPaneTarget) (*proto.Layout, bool) {
	if node == nil {
		return nil, false
	}
	switch node.Kind {
	case "pane":
		if node.Pane == nil || node.Pane.ID == "" {
			return nil, false
		}
		id := relayObjectID(host, "pane", node.Pane.ID)
		p := proto.Pane{ID: id, Title: node.Pane.Title}
		if node.Pane.Kind == "terminal" && node.Pane.SessionID != nil && *node.Pane.SessionID != "" {
			targets[id] = relayPaneTarget{host: host, session: *node.Pane.SessionID}
		} else {
			p.URL = proto.BlankURL
		}
		*panes = append(*panes, p)
		return &proto.Layout{Pane: id}, true
	case "split":
		first, ok1 := relayLayout(host, node.First, panes, targets)
		second, ok2 := relayLayout(host, node.Second, panes, targets)
		if !ok1 || !ok2 {
			return nil, false
		}
		return &proto.Layout{Row: node.Axis == "horizontal", Ratio: node.Fraction, A: first, B: second}, true
	default:
		return nil, false
	}
}

// relayTerminalConn adapts encrypted control events to the terminal's stream.
// Input entered while the lease is being granted is bounded and then sent in
// order; size changes collapse to the latest dimensions.
type relayTerminalConn struct {
	terminal      *relaybridge.Terminal
	reader        *io.PipeReader
	writer        *io.PipeWriter
	mu            sync.Mutex
	ready, closed bool
	input         []byte
	size          relaybridge.Resize
	onError       func(error)
}

func newRelayTerminalConn(t *relaybridge.Terminal, onError func(error)) *relayTerminalConn {
	r, w := io.Pipe()
	c := &relayTerminalConn{terminal: t, reader: r, writer: w, onError: onError}
	go c.run()
	return c
}
func (c *relayTerminalConn) run() {
	defer c.writer.Close()
	for event := range c.terminal.Events() {
		switch event.State {
		case "granted":
			c.mu.Lock()
			c.ready = true
			var err error
			if c.size.Columns != 0 {
				err = c.terminal.Resize(c.size)
			}
			if err == nil && len(c.input) != 0 {
				err = c.terminal.Write(c.input)
			}
			c.input = nil
			c.mu.Unlock()
			if err != nil {
				c.fail(err)
				return
			}
		case "bootstrap", "output":
			if _, err := c.writer.Write(event.Data); err != nil {
				return
			}
		case "busy", "closed":
			err := event.Err
			if err == nil {
				err = relaybridge.ErrDisconnected
			}
			c.fail(err)
			return
		}
	}
}
func (c *relayTerminalConn) fail(err error) {
	c.writer.CloseWithError(err)
	if c.onError != nil {
		c.onError(err)
	}
}
func (c *relayTerminalConn) Read(p []byte) (int, error) { return c.reader.Read(p) }
func (c *relayTerminalConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return 0, io.ErrClosedPipe
	}
	if !c.ready {
		if len(c.input)+len(p) > 64<<10 {
			return 0, relaybridge.ErrBackpressure
		}
		c.input = append(c.input, p...)
		return len(p), nil
	}
	if err := c.terminal.Write(p); err != nil {
		return 0, err
	}
	return len(p), nil
}
func (c *relayTerminalConn) ResizePixels(cols, rows, cellWidth, cellHeight int) error {
	size := relaybridge.Resize{Columns: uint16(max(1, min(cols, 65535))), Rows: uint16(max(1, min(rows, 65535))), CellWidth: uint16(max(0, min(cellWidth, 65535))), CellHeight: uint16(max(0, min(cellHeight, 65535)))}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return io.ErrClosedPipe
	}
	if !c.ready {
		c.size = size
		return nil
	}
	return c.terminal.Resize(size)
}
func (c *relayTerminalConn) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()
	c.reader.Close()
	c.writer.Close()
	return c.terminal.Close()
}

// relayControl identifies a lease hosted by this app, including one proxied
// through a configured SSH or Tailscale connection.
func (a *App) relayControl(id string) (*relaybridge.Service, string, bool) {
	if a.relay.service == nil || a.relayBackend == nil {
		return nil, "", false
	}
	h := a.hostOf(id)
	session := relayUUID(a.relayBackend.identity, "terminal", h.name+"\x00"+id)
	return a.relay.service, session, a.relay.service.HasControl(session)
}

func (a *App) ensureRelayTerm(id string, target relayPaneTarget) {
	if a.relay.service == nil {
		return
	}
	e := &termEntry{started: time.Now()}
	a.terms[id] = e
	service := a.relay.service
	backend := a.set.TerminalBackend
	options := a.termOptions(id, nil)
	options.ClipboardRead = terminal.ClipboardDeny
	options.NoClipboardWrite = true
	options.OnClear = func(terminal.Clear) bool { return true }
	options.OnScroll = nil
	options.OnPaste = nil
	options.OpenLink = func(string) bool { return true }
	go func() {
		remote, err := service.Open(target.host, target.session, relaybridge.Resize{Columns: 80, Rows: 24})
		if err != nil {
			a.update(func() {
				if a.terms[id] == e {
					e.err = err.Error()
				}
			})
			return
		}
		conn := newRelayTerminalConn(remote, func(err error) {
			a.update(func() {
				if a.terms[id] != e {
					return
				}
				if e.term != nil {
					go e.term.Close()
					e.term = nil
				}
				if errors.Is(err, relaybridge.ErrDisconnected) {
					e.err = locales.RelayControlEnded()
				} else {
					e.err = err.Error()
				}
			})
		})
		options.Conn = conn
		term, err := newTerminalSurface(backend, options)
		if err != nil {
			conn.Close()
			a.update(func() {
				if a.terms[id] == e {
					e.err = err.Error()
				}
			})
			return
		}
		a.update(func() {
			if a.terms[id] != e {
				go term.Close()
				return
			}
			if e.err != "" {
				go term.Close()
				return
			}
			e.term = term
		})
	}()
}
