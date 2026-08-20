package repository

import (
	"context"
	"database/sql"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestAPIKeyRepositoryHashLookupAndLegacyBackfillSQLite(t *testing.T) {
	repo, client := newAPIKeyRepoSQLite(t)
	ctx := context.Background()
	_, err := repo.sql.ExecContext(ctx, "ALTER TABLE api_keys ADD COLUMN key_hash VARCHAR(64)")
	require.NoError(t, err)
	_, err = repo.sql.ExecContext(ctx, "CREATE UNIQUE INDEX idx_api_keys_key_hash_unique ON api_keys (key_hash) WHERE deleted_at IS NULL AND key_hash IS NOT NULL")
	require.NoError(t, err)

	user := mustCreateAPIKeyRepoUser(t, ctx, client, "api-key-hash-compat@test.com")
	key := &service.APIKey{
		UserID: user.ID,
		Key:    "sk-api-key-hash-compat",
		Name:   "Hash compatibility",
		Status: service.StatusActive,
	}
	require.NoError(t, repo.Create(ctx, key))

	var storedHash string
	require.NoError(t, repo.sql.(*sql.DB).QueryRowContext(ctx, "SELECT key_hash FROM api_keys WHERE id = $1", key.ID).Scan(&storedHash))
	require.Equal(t, apiKeyCredentialHash(key.Key), storedHash)

	// Simulate an old row that has not been lazily backfilled yet.
	_, err = repo.sql.ExecContext(ctx, "UPDATE api_keys SET key_hash = NULL WHERE id = $1", key.ID)
	require.NoError(t, err)
	got, err := repo.GetByKeyForAuth(ctx, key.Key)
	require.NoError(t, err)
	require.Equal(t, key.ID, got.ID)
	require.NoError(t, repo.sql.(*sql.DB).QueryRowContext(ctx, "SELECT key_hash FROM api_keys WHERE id = $1", key.ID).Scan(&storedHash))
	require.Equal(t, apiKeyCredentialHash(key.Key), storedHash)
}
