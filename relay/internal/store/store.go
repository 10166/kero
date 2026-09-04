package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	_ "modernc.org/sqlite"
)

type Store struct{ db *sql.DB }

type Device struct {
	ID           string `json:"id"`
	AgreementKey string `json:"agreement_key"`
	SigningKey   string `json:"signing_key"`
	LastSeenAt   string `json:"last_seen_at"`
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(context.Background()); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS login_grants (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  challenge TEXT NOT NULL,
  callback_url TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
  id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  agreement_key TEXT NOT NULL,
  signing_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  revoked_at TEXT,
  PRIMARY KEY(account_id, id)
);
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('access','refresh')),
  expires_at TEXT NOT NULL,
  FOREIGN KEY(account_id, device_id) REFERENCES devices(account_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS devices_account ON devices(account_id);
CREATE INDEX IF NOT EXISTS sessions_account ON sessions(account_id);
`)
	return err
}

func AccountID(issuer, subject string) string {
	h := sha256.Sum256([]byte(issuer + "\x00" + subject))
	return hex.EncodeToString(h[:])
}

func HashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

func (s *Store) EnsureAccount(ctx context.Context, id string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO accounts(id,created_at) VALUES(?,?) ON CONFLICT(id) DO NOTHING`, id, time.Now().UTC().Format(time.RFC3339Nano))
	return err
}

func (s *Store) PutLoginGrant(ctx context.Context, hash, accountID, challenge, callback string, expiry time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO login_grants(token_hash,account_id,challenge,callback_url,expires_at) VALUES(?,?,?,?,?)`, hash, accountID, challenge, callback, expiry.UTC().Format(time.RFC3339Nano))
	return err
}

func (s *Store) ConsumeLoginGrant(ctx context.Context, hash string) (accountID, challenge string, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	var expiry string
	err = tx.QueryRowContext(ctx, `SELECT account_id,challenge,expires_at FROM login_grants WHERE token_hash=?`, hash).Scan(&accountID, &challenge, &expiry)
	if err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM login_grants WHERE token_hash=?`, hash); err != nil {
		return "", "", err
	}
	when, err := time.Parse(time.RFC3339Nano, expiry)
	if err != nil || time.Now().After(when) {
		return "", "", errors.New("login grant expired")
	}
	return accountID, challenge, tx.Commit()
}

func (s *Store) PutSession(ctx context.Context, token, accountID, deviceID, kind string, expiry time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO sessions(token_hash,account_id,device_id,kind,expires_at) VALUES(?,?,?,?,?)`, HashToken(token), accountID, deviceID, kind, expiry.UTC().Format(time.RFC3339Nano))
	return err
}

func (s *Store) ConsumeRefresh(ctx context.Context, token string) (accountID, deviceID string, err error) {
	hash := HashToken(token)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", "", err
	}
	defer tx.Rollback()
	var expiry string
	err = tx.QueryRowContext(ctx, `SELECT s.account_id,s.device_id,s.expires_at FROM sessions s JOIN devices d ON d.account_id=s.account_id AND d.id=s.device_id WHERE s.token_hash=? AND s.kind='refresh' AND d.revoked_at IS NULL`, hash).Scan(&accountID, &deviceID, &expiry)
	if err != nil {
		return "", "", err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM sessions WHERE token_hash=?`, hash); err != nil {
		return "", "", err
	}
	when, err := time.Parse(time.RFC3339Nano, expiry)
	if err != nil || time.Now().After(when) {
		return "", "", errors.New("refresh token expired")
	}
	return accountID, deviceID, tx.Commit()
}

func (s *Store) Authenticate(ctx context.Context, token string) (accountID, deviceID string, err error) {
	var expiry string
	err = s.db.QueryRowContext(ctx, `SELECT s.account_id,s.device_id,s.expires_at FROM sessions s JOIN devices d ON d.account_id=s.account_id AND d.id=s.device_id WHERE s.token_hash=? AND s.kind='access' AND d.revoked_at IS NULL`, HashToken(token)).Scan(&accountID, &deviceID, &expiry)
	if err != nil {
		return "", "", err
	}
	when, err := time.Parse(time.RFC3339Nano, expiry)
	if err != nil || time.Now().After(when) {
		return "", "", errors.New("access token expired")
	}
	return accountID, deviceID, nil
}

func (s *Store) EnrollDevice(ctx context.Context, accountID string, d Device) error {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := s.db.ExecContext(ctx, `INSERT INTO devices(id,account_id,agreement_key,signing_key,created_at,last_seen_at,revoked_at)
VALUES(?,?,?,?,?,?,NULL) ON CONFLICT(account_id,id) DO UPDATE SET agreement_key=excluded.agreement_key,signing_key=excluded.signing_key,last_seen_at=excluded.last_seen_at
    ,revoked_at=NULL`, d.ID, accountID, d.AgreementKey, d.SigningKey, now, now)
	return err
}

func (s *Store) UpdateDevice(ctx context.Context, accountID string, d Device) error {
	result, err := s.db.ExecContext(ctx, `UPDATE devices SET agreement_key=?,signing_key=?,last_seen_at=? WHERE id=? AND account_id=? AND revoked_at IS NULL`, d.AgreementKey, d.SigningKey, time.Now().UTC().Format(time.RFC3339Nano), d.ID, accountID)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *Store) TouchDevice(ctx context.Context, accountID, id string) error {
	result, err := s.db.ExecContext(ctx, `UPDATE devices SET last_seen_at=? WHERE id=? AND account_id=? AND revoked_at IS NULL`, time.Now().UTC().Format(time.RFC3339Nano), id, accountID)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return sql.ErrNoRows
	}
	return nil
}

func (s *Store) Devices(ctx context.Context, accountID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,agreement_key,signing_key,last_seen_at FROM devices WHERE account_id=? AND revoked_at IS NULL ORDER BY created_at`, accountID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.ID, &d.AgreementKey, &d.SigningKey, &d.LastSeenAt); err != nil {
			return nil, err
		}
		result = append(result, d)
	}
	return result, rows.Err()
}

func (s *Store) DeviceBelongsTo(ctx context.Context, accountID, id string) bool {
	var one int
	return s.db.QueryRowContext(ctx, `SELECT 1 FROM devices WHERE id=? AND account_id=? AND revoked_at IS NULL`, id, accountID).Scan(&one) == nil
}

func (s *Store) RevokeDevice(ctx context.Context, accountID, id string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE devices SET revoked_at=? WHERE id=? AND account_id=?`, time.Now().UTC().Format(time.RFC3339Nano), id, accountID)
	return err
}
