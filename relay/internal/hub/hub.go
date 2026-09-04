package hub

import (
	"context"
	"encoding/json"
	"errors"
	"sync"

	"github.com/coder/websocket"
)

const MaxFrameBytes = 2 << 20

type Peer struct {
	AccountID string
	DeviceID  string
	Conn      *websocket.Conn
	Send      chan Outbound
}

type Outbound struct {
	Kind websocket.MessageType
	Data []byte
}

type Hub struct {
	mu      sync.RWMutex
	peers   map[string]*Peer
	belongs func(context.Context, string, string) bool
}

func New(belongs func(context.Context, string, string) bool) *Hub {
	return &Hub{peers: map[string]*Peer{}, belongs: belongs}
}

func (h *Hub) Run(ctx context.Context, p *Peer) error {
	peerKey := key(p.AccountID, p.DeviceID)
	h.mu.Lock()
	if old := h.peers[peerKey]; old != nil {
		old.Conn.Close(websocket.StatusPolicyViolation, "device connected elsewhere")
	}
	h.peers[peerKey] = p
	h.broadcastPresenceLocked(p.AccountID)
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		if h.peers[peerKey] == p {
			delete(h.peers, peerKey)
			h.broadcastPresenceLocked(p.AccountID)
		}
		h.mu.Unlock()
	}()

	writeErr := make(chan error, 1)
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case message := <-p.Send:
				if err := p.Conn.Write(ctx, message.Kind, message.Data); err != nil {
					writeErr <- err
					return
				}
			}
		}
	}()
	for {
		kind, data, err := p.Conn.Read(ctx)
		if err != nil {
			return err
		}
		select {
		case err := <-writeErr:
			return err
		default:
		}
		if kind != websocket.MessageBinary || len(data) < 86 || len(data) > MaxFrameBytes {
			return errors.New("invalid encrypted frame")
		}
		// Header: version(1), type(1), recipient/sender/stream UUIDs(48), sequence(8).
		if data[0] != 1 {
			return errors.New("unsupported protocol version")
		}
		recipient := uuidString(data[2:18])
		sender := uuidString(data[18:34])
		if sender != p.DeviceID || !h.belongs(ctx, p.AccountID, recipient) {
			return errors.New("cross-account or forged route")
		}
		h.mu.RLock()
		target := h.peers[key(p.AccountID, recipient)]
		h.mu.RUnlock()
		if target == nil || target.AccountID != p.AccountID {
			continue
		}
		select {
		case target.Send <- Outbound{websocket.MessageBinary, append([]byte(nil), data...)}:
		default:
			target.Conn.Close(websocket.StatusPolicyViolation, "slow consumer")
		}
	}
}

func (h *Hub) Disconnect(accountID, deviceID string) {
	h.mu.RLock()
	p := h.peers[key(accountID, deviceID)]
	h.mu.RUnlock()
	if p != nil {
		p.Conn.Close(websocket.StatusPolicyViolation, "device revoked")
	}
}

func key(accountID, deviceID string) string { return accountID + "\x00" + deviceID }

func (h *Hub) broadcastPresenceLocked(accountID string) {
	ids := []string{}
	for _, p := range h.peers {
		if p.AccountID == accountID {
			ids = append(ids, p.DeviceID)
		}
	}
	data, _ := json.Marshal(map[string]any{"type": "presence", "online_device_ids": ids})
	for _, p := range h.peers {
		if p.AccountID == accountID {
			select {
			case p.Send <- Outbound{websocket.MessageText, data}:
			default:
			}
		}
	}
}

func uuidString(b []byte) string {
	if len(b) != 16 {
		return ""
	}
	const x = "0123456789abcdef"
	out := make([]byte, 36)
	positions := []int{8, 13, 18, 23}
	j := 0
	for i := 0; i < 36; i++ {
		if len(positions) > 0 && i == positions[0] {
			out[i] = '-'
			positions = positions[1:]
			continue
		}
		out[i] = x[b[j]>>4]
		out[i+1] = x[b[j]&15]
		i++
		j++
	}
	return string(out)
}
