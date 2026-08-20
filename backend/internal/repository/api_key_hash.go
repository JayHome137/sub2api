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
	return r.sql
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
