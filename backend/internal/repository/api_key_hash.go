package repository

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"strings"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/ent/apikey"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"

	"entgo.io/ent/dialect"
)

const apiKeyHashColumn = "key_hash"

// apiKeyCredentialHash returns the deterministic, non-reversible lookup value
// used by the compatibility migration.  The raw API key remains in the legacy
// column during the rolling migration so existing UI/API responses continue to
// work; this value is only used for authentication lookup and uniqueness.
func apiKeyCredentialHash(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:])
}

// apiKeyHashSQLExecutor prefers an Ent transaction executor when the caller is
// already inside a transaction.  Falling back to the repository executor keeps
// the helper compatible with the existing repository constructors and SQLite
// unit tests.
func (r *apiKeyRepository) apiKeyHashSQLExecutor(ctx context.Context) sqlExecutor {
	if tx := dbent.TxFromContext(ctx); tx != nil {
		if exec := sqlExecutorFromEntClient(tx.Client()); exec != nil {
			return exec
		}
	}
	if r.sql != nil {
		return r.sql
	}
	return sqlExecutorFromEntClient(r.client)
}

func (r *apiKeyRepository) apiKeyHashPlaceholder() string {
	if r.client != nil && r.client.Driver().Dialect() == dialect.SQLite {
		return "?"
	}
	return "$1"
}

// lookupAPIKeyIDByHash returns (id, available, err).  available is false when
// the migration has not reached this process's database yet; callers must then
// use the legacy plaintext lookup.  Other database errors are returned instead
// of being silently treated as a miss, so outages cannot turn into an auth
// bypass or an unbounded fallback scan.
func (r *apiKeyRepository) lookupAPIKeyIDByHash(ctx context.Context, key string) (int64, bool, error) {
	exec := r.apiKeyHashSQLExecutor(ctx)
	if exec == nil {
		return 0, false, nil
	}

	placeholder := r.apiKeyHashPlaceholder()
	query := fmt.Sprintf(`
		SELECT id
		FROM api_keys
		WHERE key_hash = %s AND deleted_at IS NULL
		LIMIT 1`, placeholder)
	var id int64
	err := scanSingleRow(ctx, exec, query, []any{apiKeyCredentialHash(key)}, &id)
	if err == nil {
		return id, true, nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return 0, true, nil
	}
	if isMissingAPIKeyHashColumn(err) {
		return 0, false, nil
	}
	return 0, true, err
}

// findAPIKeyIDByKey keeps authentication available throughout the rolling
// migration: hash-first, then legacy plaintext lookup for rows whose hash has
// not been populated yet.  A successful legacy hit is lazily backfilled.
func (r *apiKeyRepository) findAPIKeyIDByKey(ctx context.Context, key string) (int64, error) {
	if key == "" {
		return 0, service.ErrAPIKeyNotFound
	}
	id, hashAvailable, err := r.lookupAPIKeyIDByHash(ctx, key)
	if err != nil {
		return 0, err
	}
	if hashAvailable && id != 0 {
		return id, nil
	}

	client := clientFromContext(ctx, r.client)
	m, err := client.APIKey.Query().
		Where(apikey.DeletedAtIsNil(), apikey.KeyEQ(key)).
		Select(apikey.FieldID).
		Only(ctx)
	if err != nil {
		if dbent.IsNotFound(err) {
			return 0, service.ErrAPIKeyNotFound
		}
		return 0, err
	}
	if hashAvailable {
		r.backfillAPIKeyHash(ctx, m.ID, key)
	}
	return m.ID, nil
}

// GetOwnerIDAndKeyHash returns the owner and cache namespace for an active
// key.  The legacy plaintext column is consulted only when key_hash is not
// available yet (or the rolling migration has not reached this database), and
// is immediately converted to the non-reversible hash before returning.
func (r *apiKeyRepository) GetOwnerIDAndKeyHash(ctx context.Context, id int64) (int64, string, error) {
	exec := r.apiKeyHashSQLExecutor(ctx)
	if exec == nil {
		return 0, "", service.ErrAPIKeyNotFound
	}
	placeholder := r.apiKeyHashPlaceholder()
	var ownerID int64
	var keyHash sql.NullString
	query := fmt.Sprintf(`
		SELECT user_id, key_hash
		FROM api_keys
		WHERE id = %s AND deleted_at IS NULL`, placeholder)
	err := scanSingleRow(ctx, exec, query, []any{id}, &ownerID, &keyHash)
	if err != nil {
		if isMissingAPIKeyHashColumn(err) {
			return r.getOwnerIDAndKeyHashLegacy(ctx, id, exec, placeholder)
		}
		if errors.Is(err, sql.ErrNoRows) {
			return 0, "", service.ErrAPIKeyNotFound
		}
		return 0, "", err
	}
	if keyHash.Valid && strings.TrimSpace(keyHash.String) != "" {
		return ownerID, keyHash.String, nil
	}

	var legacyKey string
	legacyQuery := fmt.Sprintf(`
		SELECT key
		FROM api_keys
		WHERE id = %s AND deleted_at IS NULL`, placeholder)
	if err := scanSingleRow(ctx, exec, legacyQuery, []any{id}, &legacyKey); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, "", service.ErrAPIKeyNotFound
		}
		return 0, "", err
	}
	keyHashValue := apiKeyCredentialHash(legacyKey)
	r.backfillAPIKeyHash(ctx, id, legacyKey)
	return ownerID, keyHashValue, nil
}

func (r *apiKeyRepository) getOwnerIDAndKeyHashLegacy(ctx context.Context, id int64, exec sqlExecutor, placeholder string) (int64, string, error) {
	var ownerID int64
	var legacyKey string
	query := fmt.Sprintf(`
		SELECT user_id, key
		FROM api_keys
		WHERE id = %s AND deleted_at IS NULL`, placeholder)
	if err := scanSingleRow(ctx, exec, query, []any{id}, &ownerID, &legacyKey); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return 0, "", service.ErrAPIKeyNotFound
		}
		return 0, "", err
	}
	return ownerID, apiKeyCredentialHash(legacyKey), nil
}

// keyHashByID is used by the quota hot path after its atomic UPDATE.  It
// follows the same hash-first/legacy-null fallback as GetOwnerIDAndKeyHash.
func (r *apiKeyRepository) keyHashByID(ctx context.Context, id int64) (string, error) {
	_, keyHash, err := r.GetOwnerIDAndKeyHash(ctx, id)
	return keyHash, err
}

// listAPIKeyHashes returns only cache hashes.  During a rolling migration it
// performs a second, narrowly-scoped query for rows whose hash is NULL and
// lazily backfills those rows.  It never selects plaintext for rows that
// already have key_hash populated.
func (r *apiKeyRepository) listAPIKeyHashes(ctx context.Context, predicate string, id int64) ([]string, error) {
	exec := r.apiKeyHashSQLExecutor(ctx)
	if exec == nil {
		return nil, errors.New("api key hash SQL executor is not configured")
	}
	placeholder := r.apiKeyHashPlaceholder()
	args := []any{id}
	base := fmt.Sprintf("FROM api_keys WHERE %s = %s AND deleted_at IS NULL", predicate, placeholder)

	hashes := make([]string, 0)
	rows, err := exec.QueryContext(ctx, fmt.Sprintf("SELECT key_hash %s AND key_hash IS NOT NULL", base), args...)
	if err != nil {
		if !isMissingAPIKeyHashColumn(err) {
			return nil, err
		}
		return r.listAPIKeyHashesLegacy(ctx, predicate, id, exec, placeholder)
	}
	for rows.Next() {
		var keyHash string
		if err := rows.Scan(&keyHash); err != nil {
			_ = rows.Close()
			return nil, err
		}
		if keyHash != "" {
			hashes = append(hashes, keyHash)
		}
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}

	// Only legacy rows need the plaintext fallback. Include IDs so the
	// best-effort backfill can avoid a future plaintext read.
	legacyRows, err := exec.QueryContext(ctx, fmt.Sprintf("SELECT id, key %s AND key_hash IS NULL", base), args...)
	if err != nil {
		if isMissingAPIKeyHashColumn(err) {
			return r.listAPIKeyHashesLegacy(ctx, predicate, id, exec, placeholder)
		}
		return nil, err
	}
	type legacyKeyRow struct {
		id  int64
		key string
	}
	legacyEntries := make([]legacyKeyRow, 0)
	for legacyRows.Next() {
		var rowID int64
		var legacyKey string
		if err := legacyRows.Scan(&rowID, &legacyKey); err != nil {
			_ = legacyRows.Close()
			return nil, err
		}
		if legacyKey == "" {
			continue
		}
		legacyEntries = append(legacyEntries, legacyKeyRow{id: rowID, key: legacyKey})
	}
	if err := legacyRows.Err(); err != nil {
		_ = legacyRows.Close()
		return nil, err
	}
	if err := legacyRows.Close(); err != nil {
		return nil, err
	}
	for _, entry := range legacyEntries {
		hashes = append(hashes, apiKeyCredentialHash(entry.key))
		r.backfillAPIKeyHash(ctx, entry.id, entry.key)
	}
	return hashes, nil
}

func (r *apiKeyRepository) listAPIKeyHashesLegacy(ctx context.Context, predicate string, id int64, exec sqlExecutor, placeholder string) ([]string, error) {
	query := fmt.Sprintf("SELECT id, key FROM api_keys WHERE %s = %s AND deleted_at IS NULL", predicate, placeholder)
	rows, err := exec.QueryContext(ctx, query, id)
	if err != nil {
		return nil, err
	}
	hashes := make([]string, 0)
	for rows.Next() {
		var ignoredID int64
		var legacyKey string
		if err := rows.Scan(&ignoredID, &legacyKey); err != nil {
			_ = rows.Close()
			return nil, err
		}
		if legacyKey == "" {
			continue
		}
		hashes = append(hashes, apiKeyCredentialHash(legacyKey))
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	return hashes, nil
}

func (r *apiKeyRepository) ListKeyHashesByUserID(ctx context.Context, userID int64) ([]string, error) {
	return r.listAPIKeyHashes(ctx, "user_id", userID)
}

func (r *apiKeyRepository) ListKeyHashesByGroupID(ctx context.Context, groupID int64) ([]string, error) {
	return r.listAPIKeyHashes(ctx, "group_id", groupID)
}

// ListAPIKeyIDsByUserID is the minimal projection needed when an admin deletes
// a user and its keys. It deliberately avoids the legacy key column.
func (r *apiKeyRepository) ListAPIKeyIDsByUserID(ctx context.Context, userID int64) ([]int64, error) {
	exec := r.apiKeyHashSQLExecutor(ctx)
	if exec == nil {
		return nil, errors.New("api key ID SQL executor is not configured")
	}
	placeholder := r.apiKeyHashPlaceholder()
	query := fmt.Sprintf(`
		SELECT id
		FROM api_keys
		WHERE user_id = %s AND deleted_at IS NULL
		ORDER BY id ASC`, placeholder)
	rows, err := exec.QueryContext(ctx, query, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	ids := make([]int64, 0)
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// backfillAPIKeyHash is deliberately best-effort.  During a rolling upgrade
// an older instance may race the migration, and returning an error after the
// Ent insert has committed would make clients retry a successful create and
// receive a misleading duplicate-key error.  Authentication remains correct
// through the legacy fallback; non-compatibility failures are logged without
// exposing credential material.
func (r *apiKeyRepository) backfillAPIKeyHash(ctx context.Context, id int64, key string) {
	if id <= 0 || key == "" {
		return
	}
	exec := r.apiKeyHashSQLExecutor(ctx)
	if exec == nil {
		return
	}

	placeholder := r.apiKeyHashPlaceholder()
	second := "$2"
	if placeholder == "?" {
		second = "?"
	}
	query := fmt.Sprintf(`
		UPDATE api_keys
		SET key_hash = %s
		WHERE id = %s AND deleted_at IS NULL AND key_hash IS NULL`, placeholder, second)
	if _, err := exec.ExecContext(ctx, query, apiKeyCredentialHash(key), id); err != nil {
		if isMissingAPIKeyHashColumn(err) {
			return
		}
		slog.Warn("api key hash backfill failed", "api_key_id", id, "error", err)
	}
}

func isMissingAPIKeyHashColumn(err error) bool {
	if err == nil {
		return false
	}
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		return pqErr.Code == "42703" // undefined_column
	}
	msg := strings.ToLower(err.Error())
	return (strings.Contains(msg, "no such column") && strings.Contains(msg, apiKeyHashColumn)) ||
		strings.Contains(msg, "column \""+apiKeyHashColumn+"\" does not exist")
}
