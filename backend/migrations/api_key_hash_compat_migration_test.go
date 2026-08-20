package migrations

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestAPIKeyHashCompatibilityMigrationsPreserveRollingUpgradeBoundary(t *testing.T) {
	column, err := FS.ReadFile("227_api_key_hash_compat.sql")
	require.NoError(t, err)
	columnSQL := strings.ToLower(strings.Join(strings.Fields(string(column)), " "))
	require.Contains(t, columnSQL, "add column if not exists key_hash varchar(64)")
	require.Contains(t, columnSQL, "nullable")
	require.NotContains(t, columnSQL, "drop column")
	require.NotContains(t, columnSQL, "rename column")

	index, err := FS.ReadFile("228_api_key_hash_unique_index_notx.sql")
	require.NoError(t, err)
	indexSQL := strings.ToLower(strings.Join(strings.Fields(string(index)), " "))
	require.Contains(t, indexSQL, "create unique index concurrently if not exists idx_api_keys_key_hash_unique")
	require.Contains(t, indexSQL, "on api_keys (key_hash)")
	require.Contains(t, indexSQL, "where deleted_at is null and key_hash is not null")
}
