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
	row := repo.sql.(*sql.DB).QueryRowContext(ctx, "SELECT key_hash FROM api_keys WHERE id = $1", key.ID)
	err = row.Scan(&storedHash)
	require.NoError(t, err)
	require.Equal(t, apiKeyCredentialHash(key.Key), storedHash)

	// Simulate an old row that has not been lazily backfilled yet.
	_, err = repo.sql.ExecContext(ctx, "UPDATE api_keys SET key_hash = NULL WHERE id = $1", key.ID)
	require.NoError(t, err)
	got, err := repo.GetByKeyForAuth(ctx, key.Key)
	require.NoError(t, err)
	require.Equal(t, key.ID, got.ID)
	row = repo.sql.(*sql.DB).QueryRowContext(ctx, "SELECT key_hash FROM api_keys WHERE id = $1", key.ID)
	err = row.Scan(&storedHash)
	require.NoError(t, err)
	require.Equal(t, apiKeyCredentialHash(key.Key), storedHash)

	// Delete/cache invalidation callers can obtain only the owner and hash;
	// they do not need to materialize the legacy credential in the service.
	_, err = repo.sql.ExecContext(ctx, "UPDATE api_keys SET key_hash = NULL WHERE id = $1", key.ID)
	require.NoError(t, err)
	ownerID, keyHash, err := repo.GetOwnerIDAndKeyHash(ctx, key.ID)
	require.NoError(t, err)
	require.Equal(t, user.ID, ownerID)
	require.Equal(t, apiKeyCredentialHash(key.Key), keyHash)
	require.NoError(t, repo.sql.(*sql.DB).QueryRowContext(ctx, "SELECT key_hash FROM api_keys WHERE id = $1", key.ID).Scan(&storedHash))
	require.Equal(t, keyHash, storedHash)

	hashes, err := repo.ListKeyHashesByUserID(ctx, user.ID)
	require.NoError(t, err)
	require.Equal(t, []string{keyHash}, hashes)
	hashes, err = repo.ListKeyHashesByGroupID(ctx, 999999)
	require.NoError(t, err)
	require.Empty(t, hashes)
}

func TestAPIKeyRepositoryHashHelpersFallbackWithoutMigrationSQLite(t *testing.T) {
	repo, client := newAPIKeyRepoSQLite(t)
	ctx := context.Background()
	user := mustCreateAPIKeyRepoUser(t, ctx, client, "api-key-hash-legacy@test.com")
	key := &service.APIKey{
		UserID: user.ID,
		Key:    "sk-api-key-hash-legacy",
		Name:   "Legacy hash fallback",
		Status: service.StatusActive,
	}
	require.NoError(t, repo.Create(ctx, key))

	ownerID, keyHash, err := repo.GetOwnerIDAndKeyHash(ctx, key.ID)
	require.NoError(t, err)
	require.Equal(t, user.ID, ownerID)
	require.Equal(t, apiKeyCredentialHash(key.Key), keyHash)
	hashes, err := repo.ListKeyHashesByUserID(ctx, user.ID)
	require.NoError(t, err)
	require.Equal(t, []string{keyHash}, hashes)
}
