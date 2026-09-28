-- Per-group degradation (降智) detection settings and results.
-- Settings: one row per group that ever enabled quality checks.
-- Results: one row per account probe; the group status is aggregated from
-- the recent window so user-facing status stays cheap to compute.
CREATE TABLE IF NOT EXISTS group_quality_check_settings (
    group_id         BIGINT PRIMARY KEY REFERENCES groups(id) ON DELETE CASCADE,
    enabled          BOOLEAN NOT NULL DEFAULT false,
    interval_minutes INT NOT NULL DEFAULT 15,
    last_run_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
