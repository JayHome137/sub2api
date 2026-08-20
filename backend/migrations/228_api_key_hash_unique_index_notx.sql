-- Hash lookup/uniqueness index for the API key compatibility migration.
--
-- This is non-transactional so a large production table can build the index
-- concurrently without blocking authentication writes.  The partial
-- predicate excludes soft-deleted rows and the nullable legacy rows that are
-- waiting for lazy backfill.
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_api_keys_key_hash_unique
    ON api_keys (key_hash)
    WHERE deleted_at IS NULL AND key_hash IS NOT NULL;
