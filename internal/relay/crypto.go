package relay

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"sync"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
)

const (
	FrameHeaderLength = 58
	FrameOverhead     = 28
	MaxFrameBytes     = 2 << 20
)

type FrameKind byte

const (
	KindTopology FrameKind = 1 + iota
	KindAttach
	KindGranted
	KindBusy
	KindBootstrap
	KindOutput
	KindInput
	KindResize
	KindRelease
	KindHello
)

var (
	ErrInvalidFrame      = errors.New("relay: invalid frame")
	ErrWrongRoute        = errors.New("relay: wrong frame route")
	ErrReplay            = errors.New("relay: replayed or out-of-order frame")
	ErrSequenceExhausted = errors.New("relay: sequence exhausted")
)

type Frame struct {
	Kind                            FrameKind
	RecipientID, SenderID, StreamID string
	Sequence                        uint64
	Ciphertext                      []byte
}
type sequenceKey struct{ device, stream string }
type sendSequence struct {
	next      uint64
	exhausted bool
}

// Cipher tracks per-device, per-stream sequences. Keep it across reconnects;
// use a new stream UUID when starting a fresh communication epoch.
type Cipher struct {
	identity *Identity
	mu       sync.Mutex
	sent     map[sequenceKey]sendSequence
	received map[sequenceKey]uint64
}

func NewCipher(identity *Identity) *Cipher {
	return &Cipher{identity: identity, sent: make(map[sequenceKey]sendSequence), received: make(map[sequenceKey]uint64)}
}

func pairKey(identity *Identity, peer Device) ([]byte, error) {
	if identity == nil || identity.agreement == nil {
		return nil, errors.New("relay: missing identity")
	}
	id, err := normalizeUUID(identity.ID)
	if err != nil {
		return nil, err
	}
	peerID, err := normalizeUUID(peer.ID)
	if err != nil {
		return nil, err
	}
	data, err := base64.StdEncoding.DecodeString(peer.AgreementKey)
	if err != nil {
		return nil, fmt.Errorf("relay: invalid agreement key: %w", err)
	}
	pub, err := ecdh.X25519().NewPublicKey(data)
	if err != nil {
		return nil, fmt.Errorf("relay: invalid agreement key: %w", err)
	}
	shared, err := identity.agreement.ECDH(pub)
	if err != nil {
		return nil, fmt.Errorf("relay: key agreement: %w", err)
	}
	ids := []string{id, peerID}
	sort.Strings(ids)
	key := make([]byte, chacha20poly1305.KeySize)
	_, err = io.ReadFull(hkdf.New(sha256.New, shared, []byte(ids[0]+"\x00"+ids[1]), []byte("kero-remote-v1")), key)
	return key, err
}

// Seal produces the Swift header followed by nonce, ciphertext, and tag.
func (c *Cipher) Seal(plaintext []byte, kind FrameKind, recipient Device, streamID string) ([]byte, error) {
	if c == nil || c.identity == nil || kind < KindTopology || kind > KindHello || len(plaintext) > MaxFrameBytes-FrameHeaderLength-FrameOverhead {
		return nil, ErrInvalidFrame
	}
	receiver, err := parseUUID(recipient.ID)
	if err != nil {
		return nil, err
	}
	sender, err := parseUUID(c.identity.ID)
	if err != nil {
		return nil, err
	}
	stream, err := parseUUID(streamID)
	if err != nil {
		return nil, err
	}
	key, err := pairKey(c.identity, recipient)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	var nonce [chacha20poly1305.NonceSize]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	seqKey := sequenceKey{uuidString(receiver[:]), uuidString(stream[:])}
	c.mu.Lock()
	defer c.mu.Unlock()
	seq := c.sent[seqKey]
	if seq.exhausted {
		return nil, ErrSequenceExhausted
	}
	frame := make([]byte, FrameHeaderLength, FrameHeaderLength+FrameOverhead+len(plaintext))
	frame[0], frame[1] = 1, byte(kind)
	copy(frame[2:18], receiver[:])
	copy(frame[18:34], sender[:])
	copy(frame[34:50], stream[:])
	binary.BigEndian.PutUint64(frame[50:58], seq.next)
	frame = append(frame, nonce[:]...)
	frame = aead.Seal(frame, nonce[:], plaintext, frame[:FrameHeaderLength])
	if seq.next == math.MaxUint64 {
		seq.exhausted = true
	} else {
		seq.next++
	}
	c.sent[seqKey] = seq
	return frame, nil
}

// FrameSender returns the untrusted sender ID to select a record for Open.
func FrameSender(data []byte) (string, error) {
	if len(data) < FrameHeaderLength+FrameOverhead || len(data) > MaxFrameBytes || data[0] != 1 || FrameKind(data[1]) < KindTopology || FrameKind(data[1]) > KindHello {
		return "", ErrInvalidFrame
	}
	return uuidString(data[18:34]), nil
}

// Open authenticates the header and payload before changing replay state.
func (c *Cipher) Open(data []byte, sender Device) (Frame, []byte, error) {
	var frame Frame
	if _, err := FrameSender(data); err != nil {
		return frame, nil, err
	}
	if c == nil || c.identity == nil {
		return frame, nil, ErrInvalidFrame
	}
	recipientID, err := normalizeUUID(c.identity.ID)
	if err != nil {
		return frame, nil, err
	}
	senderID, err := normalizeUUID(sender.ID)
	if err != nil {
		return frame, nil, err
	}
	frame = Frame{Kind: FrameKind(data[1]), RecipientID: uuidString(data[2:18]), SenderID: uuidString(data[18:34]), StreamID: uuidString(data[34:50]), Sequence: binary.BigEndian.Uint64(data[50:58]), Ciphertext: data[58:]}
	if frame.RecipientID != recipientID || frame.SenderID != senderID {
		return Frame{}, nil, ErrWrongRoute
	}
	key, err := pairKey(c.identity, sender)
	if err != nil {
		return Frame{}, nil, err
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return Frame{}, nil, err
	}
	plaintext, err := aead.Open(nil, data[58:70], data[70:], data[:58])
	if err != nil {
		return Frame{}, nil, fmt.Errorf("relay: authenticate frame: %w", err)
	}
	seqKey := sequenceKey{senderID, frame.StreamID}
	c.mu.Lock()
	defer c.mu.Unlock()
	if last, ok := c.received[seqKey]; ok && frame.Sequence <= last {
		return Frame{}, nil, ErrReplay
	}
	c.received[seqKey] = frame.Sequence
	return frame, plaintext, nil
}
