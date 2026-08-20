-- API key hash compatibility foundation.
--
-- The legacy `key` column is intentionally retained for rolling-upgrade
-- compatibility: older binaries, existing UI responses, and audit/cache
-- invalidation paths still read it.  New repository code writes SHA-256 to
-- this nullable column and authenticates hash-first, falling back to `key` for
-- rows that have not been lazily backfilled yet.
--
-- Do not make this column NOT NULL or rename/drop `key` in this migration.
-- That is a separate, versioned cleanup phase after all deployed readers have
-- moved away from plaintext storage.
ALTER TABLE api_keys
    ADD COLUMN IF NOT EXISTS key_hash VARCHAR(64);

COMMENT ON COLUMN api_keys.key_hash IS
    'SHA-256 hex digest of the API key; nullable during rolling plaintext compatibility migration';
