-- Independent scheduled channel quality checks.
-- Results are scoped to groups/channels and never retain account credentials or output.

CREATE TABLE IF NOT EXISTS channel_quality_config (
    id               BIGINT PRIMARY KEY CHECK (id = 1),
    enabled          BOOLEAN NOT NULL DEFAULT FALSE,
    interval_seconds INT NOT NULL DEFAULT 900,
    model            VARCHAR(200) NOT NULL DEFAULT '',
    prompt           TEXT NOT NULL DEFAULT 'Reply with exactly: QUALITY_OK',
    expected_answer  VARCHAR(200) NOT NULL DEFAULT 'QUALITY_OK',
    history_limit    INT NOT NULL DEFAULT 100,
    last_run_at      TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT channel_quality_config_interval_check CHECK (interval_seconds BETWEEN 60 AND 86400),
    CONSTRAINT channel_quality_config_history_check CHECK (history_limit BETWEEN 10 AND 1000)
);

INSERT INTO channel_quality_config (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS channel_quality_results (
    id           BIGSERIAL PRIMARY KEY,
    group_id     BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    channel_id   BIGINT REFERENCES channels(id) ON DELETE SET NULL,
    group_name   VARCHAR(100) NOT NULL DEFAULT '',
    channel_name VARCHAR(100) NOT NULL DEFAULT '',
    platform     VARCHAR(50) NOT NULL DEFAULT '',
    model        VARCHAR(200) NOT NULL DEFAULT '',
    status       VARCHAR(20) NOT NULL,
    message      VARCHAR(500) NOT NULL DEFAULT '',
    latency_ms   BIGINT,
    checked_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT channel_quality_results_status_check CHECK (status IN ('healthy', 'degraded', 'unknown', 'running'))
);

CREATE INDEX IF NOT EXISTS idx_channel_quality_results_group_checked
    ON channel_quality_results (group_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_channel_quality_results_channel_checked
    ON channel_quality_results (channel_id, checked_at DESC);
