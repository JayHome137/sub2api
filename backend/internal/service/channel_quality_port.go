package service

import (
	"context"
	"time"
)

const (
	ChannelQualityHealthy  = "healthy"
	ChannelQualityDegraded = "degraded"
	ChannelQualityUnknown  = "unknown"
	ChannelQualityRunning  = "running"

	ChannelQualityDefaultInterval = 15 * time.Minute
	ChannelQualityDefaultPrompt   = "Reply with exactly: QUALITY_OK"
	ChannelQualityDefaultExpected = "QUALITY_OK"
)

// ChannelQualityConfig is independent from channel monitor configuration.
type ChannelQualityConfig struct {
	Enabled         bool       `json:"enabled"`
	IntervalSeconds int        `json:"interval_seconds"`
	Model           string     `json:"model"`
	Prompt          string     `json:"prompt"`
	ExpectedAnswer  string     `json:"expected_answer"`
	HistoryLimit    int        `json:"history_limit"`
	LastRunAt       *time.Time `json:"last_run_at,omitempty"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

type ChannelQualityResult struct {
	ID          int64     `json:"id"`
	GroupID     int64     `json:"group_id"`
	ChannelID   *int64    `json:"channel_id,omitempty"`
	GroupName   string    `json:"group_name"`
	ChannelName string    `json:"channel_name"`
	Platform    string    `json:"platform"`
	Model       string    `json:"model"`
	Status      string    `json:"status"`
	Message     string    `json:"message"`
	LatencyMs   *int64    `json:"latency_ms,omitempty"`
	CheckedAt   time.Time `json:"checked_at"`
}

type ChannelQualityView struct {
	GroupID     int64                  `json:"group_id"`
	ChannelID   *int64                 `json:"channel_id,omitempty"`
	GroupName   string                 `json:"group_name"`
	ChannelName string                 `json:"channel_name"`
	Platform    string                 `json:"platform"`
	Model       string                 `json:"model"`
	Status      string                 `json:"status"`
	Message     string                 `json:"message"`
	LatencyMs   *int64                 `json:"latency_ms,omitempty"`
	CheckedAt   *time.Time             `json:"checked_at,omitempty"`
	Timeline    []ChannelQualityResult `json:"timeline"`
}

type ChannelQualityRepository interface {
	GetConfig(ctx context.Context) (*ChannelQualityConfig, error)
	UpdateConfig(ctx context.Context, config *ChannelQualityConfig) (*ChannelQualityConfig, error)
	CreateResult(ctx context.Context, result *ChannelQualityResult) (*ChannelQualityResult, error)
	UpdateResult(ctx context.Context, result *ChannelQualityResult) error
	ListLatest(ctx context.Context, groupIDs []int64, historyLimit int) ([]*ChannelQualityView, error)
	ListHistory(ctx context.Context, groupID int64, limit int) ([]*ChannelQualityResult, error)
}
