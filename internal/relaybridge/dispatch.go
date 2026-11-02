package relaybridge

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"kero/internal/relay"
)

func (s *Service) receive(data []byte) {
	id, err := relay.FrameSender(data)
	if err != nil {
		return
	}
	s.mu.Lock()
	p := s.peers[id]
	if p == nil || !p.online {
		s.mu.Unlock()
		return
	}
	device := p.device
	s.mu.Unlock()
	frame, plain, err := s.cipher.Open(data, device)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	p = s.peers[id]
	if p == nil || !p.online || p.device.AgreementKey != device.AgreementKey || p.device.SigningKey != device.SigningKey || s.sock == nil {
		return
	}
	switch frame.Kind {
	case relay.KindHello:
		var h hello
		if json.Unmarshal(plain, &h) != nil || p.retired[frame.StreamID] {
			return
		}
		changed := p.epoch != frame.StreamID
		if changed {
			s.clearPeerLocked(id, p, true)
			p.online = true
			p.epoch = frame.StreamID
		}
		p.hello = h
		if !h.HostEnabled {
			p.topology = nil
			for key, t := range s.terminals {
				if key.host == id {
					delete(s.terminals, key)
					t.finishLocked("closed", ErrUnavailable)
				}
			}
		}
		if changed {
			s.sendJSONLocked(id, relay.KindHello, s.epoch, hello{s.name, s.hostEnabled})
			if s.hostEnabled {
				go s.TopologyChanged()
			}
		}
		s.changed()
	case relay.KindTopology:
		var topology Topology
		if p.epoch != frame.StreamID || !p.hello.HostEnabled || json.Unmarshal(plain, &topology) != nil {
			return
		}
		if p.topology == nil || topology.Revision >= p.topology.Revision {
			p.topology = &topology
			s.changed()
		}
	case relay.KindAttach:
		var request attachRequest
		if json.Unmarshal(plain, &request) != nil {
			return
		}
		request.RequestID = strings.ToLower(request.RequestID)
		request.SessionID = strings.ToLower(request.SessionID)
		request.ControllerEpoch = strings.ToLower(request.ControllerEpoch)
		request.HostEpoch = strings.ToLower(request.HostEpoch)
		if request.RequestID != frame.StreamID || !validUUID(request.SessionID) || p.epoch == "" || request.ControllerEpoch != p.epoch || request.HostEpoch != s.epoch {
			return
		}
		if !s.hostEnabled || s.backend == nil || request.Columns == 0 || request.Rows == 0 {
			s.respondLocked(id, frame.StreamID, request.SessionID, "Terminal is unavailable.")
			return
		}
		if s.controls[request.SessionID] != nil {
			s.respondLocked(id, frame.StreamID, request.SessionID, "Terminal is already controlled.")
			return
		}
		ctx, cancel := context.WithCancel(context.Background())
		c := &control{session: request.SessionID, controller: id, stream: frame.StreamID, peerEpoch: p.epoch, localEpoch: s.epoch, ctx: ctx, cancel: cancel}
		s.controls[c.session] = c
		size := Resize{SessionID: c.session, Columns: request.Columns, Rows: request.Rows, CellWidth: request.CellWidth, CellHeight: request.CellHeight}
		go s.acquire(c, size)
	case relay.KindGranted, relay.KindBusy:
		var response attachResponse
		if json.Unmarshal(plain, &response) != nil {
			return
		}
		response.SessionID = strings.ToLower(response.SessionID)
		response.RequestID = strings.ToLower(response.RequestID)
		key := terminalKey{id, response.SessionID}
		t := s.terminals[key]
		if t == nil || t.stream != frame.StreamID || response.RequestID != frame.StreamID || p.epoch != t.hostEpoch || s.epoch != t.localEpoch || t.granted {
			return
		}
		if frame.Kind == relay.KindBusy {
			delete(s.terminals, key)
			reason := response.Reason
			if reason == "" {
				reason = "Terminal is already controlled."
			}
			t.finishLocked("busy", errors.New(reason))
		} else {
			t.granted = true
			if !t.eventLocked(TerminalEvent{State: "granted"}) {
				delete(s.terminals, key)
				s.sendJSONLocked(id, relay.KindRelease, t.stream, sessionReference{t.session})
				t.finishLocked("closed", ErrBackpressure)
			}
		}
	case relay.KindBootstrap, relay.KindOutput:
		t := s.terminalByStreamLocked(id, frame.StreamID)
		if t == nil || !t.granted || p.epoch != t.hostEpoch || s.epoch != t.localEpoch {
			return
		}
		if frame.Kind == relay.KindBootstrap {
			if t.bootstrapped {
				return
			}
			t.bootstrapped = true
		} else if !t.bootstrapped {
			return
		}
		state := "output"
		if frame.Kind == relay.KindBootstrap {
			state = "bootstrap"
		}
		if !t.dataLocked(state, plain) {
			delete(s.terminals, terminalKey{id, t.session})
			s.sendJSONLocked(id, relay.KindRelease, t.stream, sessionReference{t.session})
			t.finishLocked("closed", ErrBackpressure)
		}
	case relay.KindInput:
		c := s.controlByStreamLocked(id, frame.StreamID)
		if c == nil || c.lease == nil || p.epoch != c.peerEpoch || s.epoch != c.localEpoch {
			return
		}
		for len(plain) > 0 {
			n := len(plain)
			if n > eventChunk {
				n = eventChunk
			}
			if !c.commandLocked(leaseCommand{data: append([]byte(nil), plain[:n]...)}) {
				s.reclaimLocked(c.session)
				break
			}
			plain = plain[n:]
		}
	case relay.KindResize:
		var size Resize
		if json.Unmarshal(plain, &size) != nil {
			return
		}
		size.SessionID = strings.ToLower(size.SessionID)
		c := s.controls[size.SessionID]
		if c == nil || c.controller != id || c.stream != frame.StreamID || c.lease == nil || p.epoch != c.peerEpoch || s.epoch != c.localEpoch || size.Columns == 0 || size.Rows == 0 {
			return
		}
		if !c.commandLocked(leaseCommand{size: &size}) {
			s.reclaimLocked(c.session)
		}
	case relay.KindRelease:
		var ref sessionReference
		if json.Unmarshal(plain, &ref) != nil {
			return
		}
		ref.SessionID = strings.ToLower(ref.SessionID)
		if c := s.controls[ref.SessionID]; c != nil && c.controller == id && c.stream == frame.StreamID && p.epoch == c.peerEpoch && s.epoch == c.localEpoch {
			delete(s.controls, ref.SessionID)
			releaseControl(c)
			return
		}
		key := terminalKey{id, ref.SessionID}
		if t := s.terminals[key]; t != nil && t.stream == frame.StreamID && p.epoch == t.hostEpoch && s.epoch == t.localEpoch {
			delete(s.terminals, key)
			t.finishLocked("closed", errors.New("control was reclaimed on the host"))
		}
	}
}
func (s *Service) respondLocked(id, stream, session, reason string) {
	s.sendJSONLocked(id, relay.KindBusy, stream, attachResponse{RequestID: stream, SessionID: session, Reason: reason})
}
func (s *Service) controlByStreamLocked(id, stream string) *control {
	for _, c := range s.controls {
		if c.controller == id && c.stream == stream {
			return c
		}
	}
	return nil
}
func (s *Service) terminalByStreamLocked(id, stream string) *Terminal {
	for key, t := range s.terminals {
		if key.host == id && t.stream == stream {
			return t
		}
	}
	return nil
}

type leaseCommand struct {
	data []byte
	size *Resize
}

func (c *control) commandLocked(cmd leaseCommand) bool {
	select {
	case c.commands <- cmd:
		return true
	default:
		return false
	}
}
func (s *Service) acquire(c *control, size Resize) {
	lease, bootstrap, err := s.backend.Acquire(c.ctx, c.session, size)
	s.mu.Lock()
	if s.controls[c.session] != c || s.epoch != c.localEpoch || !s.hostEnabled {
		s.mu.Unlock()
		if lease != nil {
			lease.Release()
		}
		return
	}
	if err != nil || lease == nil {
		delete(s.controls, c.session)
		s.respondLocked(c.controller, c.stream, c.session, "Terminal is unavailable.")
		c.cancel()
		s.mu.Unlock()
		if lease != nil {
			lease.Release()
		}
		return
	}
	c.lease = lease
	c.commands = make(chan leaseCommand, 128)
	commands := c.commands
	if s.sendJSONLocked(c.controller, relay.KindGranted, c.stream, attachResponse{RequestID: c.stream, SessionID: c.session}) != nil {
		delete(s.controls, c.session)
		releaseControl(c)
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()
	go s.leaseCommands(c, commands)
	first := true
	for first || len(bootstrap) > 0 {
		n := len(bootstrap)
		if n > 512<<10 {
			n = 512 << 10
		}
		kind := relay.KindOutput
		if first {
			kind = relay.KindBootstrap
		}
		first = false
		if !s.sendBootstrap(c, kind, bootstrap[:n]) {
			return
		}
		bootstrap = bootstrap[n:]
	}
	for output := range lease.Output() {
		s.mu.Lock()
		if s.controls[c.session] != c {
			s.mu.Unlock()
			return
		}
		for len(output) > 0 {
			n := len(output)
			if n > eventChunk {
				n = eventChunk
			}
			err = s.sendLocked(c.controller, relay.KindOutput, c.stream, output[:n])
			if err != nil {
				s.reclaimLocked(c.session)
				s.mu.Unlock()
				return
			}
			output = output[n:]
		}
		s.mu.Unlock()
	}
	s.mu.Lock()
	if s.controls[c.session] == c {
		s.reclaimLocked(c.session)
	}
	s.mu.Unlock()
}

// Bootstrap can be larger than the socket queue. Wait for space while the
// writer drains it, and stop immediately if ownership is revoked.
func (s *Service) sendBootstrap(c *control, kind relay.FrameKind, data []byte) bool {
	for {
		s.mu.Lock()
		if s.controls[c.session] != c || s.sock == nil {
			s.mu.Unlock()
			return false
		}
		if len(s.out) < maxQueuedFrames && s.queuedBytes+len(data)+relay.FrameHeaderLength+relay.FrameOverhead <= maxQueuedBytes {
			err := s.sendLocked(c.controller, kind, c.stream, data)
			if err != nil {
				s.reclaimLocked(c.session)
			}
			s.mu.Unlock()
			return err == nil
		}
		s.mu.Unlock()
		select {
		case <-c.ctx.Done():
			return false
		case <-s.queueSpace:
		}
	}
}
func (s *Service) leaseCommands(c *control, commands <-chan leaseCommand) {
	for {
		select {
		case <-c.ctx.Done():
			return
		case cmd, ok := <-commands:
			if !ok || c.ctx.Err() != nil {
				return
			}
			var err error
			if cmd.size != nil {
				err = c.lease.Resize(*cmd.size)
			} else {
				err = c.lease.Write(cmd.data)
			}
			if err != nil {
				s.mu.Lock()
				if s.controls[c.session] == c {
					s.reclaimLocked(c.session)
				}
				s.mu.Unlock()
				return
			}
		}
	}
}
