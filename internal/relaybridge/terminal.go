package relaybridge

import (
	"strings"

	"kero/internal/relay"
)

// Terminal represents one remote attach stream. It is safe for concurrent use.
type Terminal struct {
	service                                      *Service
	host, session, stream, hostEpoch, localEpoch string
	granted, bootstrapped, closed                bool
	events                                       chan TerminalEvent
}

func (t *Terminal) Events() <-chan TerminalEvent { return t.events }

// Open requests exclusive remote control. Events reports whether it was granted.
func (s *Service) Open(hostID, sessionID string, size Resize) (*Terminal, error) {
	hostID = strings.ToLower(hostID)
	sessionID = strings.ToLower(sessionID)
	if !validUUID(hostID) || !validUUID(sessionID) || size.Columns == 0 || size.Rows == 0 {
		return nil, ErrUnavailable
	}
	stream, err := newUUID()
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.peers[hostID]
	if p == nil || !p.online || p.epoch == "" || !p.hello.HostEnabled || s.sock == nil {
		return nil, ErrUnavailable
	}
	key := terminalKey{hostID, sessionID}
	if s.terminals[key] != nil {
		return nil, ErrUnavailable
	}
	t := &Terminal{service: s, host: hostID, session: sessionID, stream: stream, hostEpoch: p.epoch, localEpoch: s.epoch, events: make(chan TerminalEvent, eventBuffer)}
	s.terminals[key] = t
	req := attachRequest{RequestID: stream, SessionID: sessionID, ControllerEpoch: s.epoch, HostEpoch: p.epoch, Columns: size.Columns, Rows: size.Rows, CellWidth: size.CellWidth, CellHeight: size.CellHeight}
	if err = s.sendJSONLocked(hostID, relay.KindAttach, stream, req); err != nil {
		delete(s.terminals, key)
		return nil, err
	}
	return t, nil
}
func (t *Terminal) eventLocked(event TerminalEvent) bool {
	if t.closed {
		return false
	}
	select {
	case t.events <- event:
		return true
	default:
		return false
	}
}
func (t *Terminal) dataLocked(state string, data []byte) bool {
	if len(data) == 0 {
		return t.eventLocked(TerminalEvent{State: state, Data: []byte{}})
	}
	for len(data) > 0 {
		n := len(data)
		if n > eventChunk {
			n = eventChunk
		}
		if !t.eventLocked(TerminalEvent{State: state, Data: append([]byte(nil), data[:n]...)}) {
			return false
		}
		data = data[n:]
		state = "output"
	}
	return true
}
func (t *Terminal) finishLocked(state string, err error) {
	if t.closed {
		return
	}
	t.closed = true
	// A slow consumer must still observe termination; queued output is invalid
	// after overflow or disconnect, so make room for the final event.
	select {
	case t.events <- TerminalEvent{State: state, Err: err}:
	default:
		select {
		case <-t.events:
		default:
		}
		t.events <- TerminalEvent{State: state, Err: err}
	}
	close(t.events)
}
func (t *Terminal) activeLocked() bool {
	return !t.closed && t.service.terminals[terminalKey{t.host, t.session}] == t && t.granted
}
func (t *Terminal) Write(data []byte) error {
	s := t.service
	s.mu.Lock()
	defer s.mu.Unlock()
	if !t.activeLocked() {
		return ErrDisconnected
	}
	for len(data) > 0 {
		n := len(data)
		if n > eventChunk {
			n = eventChunk
		}
		if err := s.sendLocked(t.host, relay.KindInput, t.stream, data[:n]); err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}
func (t *Terminal) Resize(size Resize) error {
	if size.Columns == 0 || size.Rows == 0 {
		return ErrUnavailable
	}
	size.SessionID = t.session
	s := t.service
	s.mu.Lock()
	defer s.mu.Unlock()
	if !t.activeLocked() {
		return ErrDisconnected
	}
	return s.sendJSONLocked(t.host, relay.KindResize, t.stream, size)
}
func (t *Terminal) Close() error {
	s := t.service
	s.mu.Lock()
	defer s.mu.Unlock()
	if t.closed {
		return nil
	}
	delete(s.terminals, terminalKey{t.host, t.session})
	err := s.sendJSONLocked(t.host, relay.KindRelease, t.stream, sessionReference{t.session})
	t.finishLocked("closed", nil)
	return err
}
