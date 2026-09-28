package repository

import (
	"context"
	"database/sql"
	"fmt"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"
)

type channelQualityRepository struct{ db *sql.DB }

func NewChannelQualityRepository(db *sql.DB) service.ChannelQualityRepository {
	return &channelQualityRepository{db: db}
}

func (r *channelQualityRepository) GetConfig(ctx context.Context) (*service.ChannelQualityConfig, error) {
	var out service.ChannelQualityConfig
	err := r.db.QueryRowContext(ctx, `
		SELECT enabled, interval_seconds, model, prompt, expected_answer, history_limit, last_run_at, updated_at
		FROM channel_quality_config WHERE id = 1`).Scan(
		&out.Enabled, &out.IntervalSeconds, &out.Model, &out.Prompt, &out.ExpectedAnswer,
		&out.HistoryLimit, &out.LastRunAt, &out.UpdatedAt)
	if err == sql.ErrNoRows {
		return &service.ChannelQualityConfig{
			IntervalSeconds: int(service.ChannelQualityDefaultInterval.Seconds()),
			Prompt:          service.ChannelQualityDefaultPrompt,
			ExpectedAnswer:  service.ChannelQualityDefaultExpected,
			HistoryLimit:    100,
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get channel quality config: %w", err)
	}
	return &out, nil
}

func (r *channelQualityRepository) UpdateConfig(ctx context.Context, config *service.ChannelQualityConfig) (*service.ChannelQualityConfig, error) {
	updated := &service.ChannelQualityConfig{}
	err := r.db.QueryRowContext(ctx, `
		UPDATE channel_quality_config
		SET enabled=$1, interval_seconds=$2, model=$3, prompt=$4, expected_answer=$5, history_limit=$6, updated_at=NOW()
		WHERE id=1
		RETURNING enabled, interval_seconds, model, prompt, expected_answer, history_limit, last_run_at, updated_at`,
		config.Enabled, config.IntervalSeconds, strings.TrimSpace(config.Model), config.Prompt,
		config.ExpectedAnswer, config.HistoryLimit).Scan(
		&updated.Enabled, &updated.IntervalSeconds, &updated.Model, &updated.Prompt,
		&updated.ExpectedAnswer, &updated.HistoryLimit, &updated.LastRunAt, &updated.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("update channel quality config: %w", err)
	}
	return updated, nil
}

func (r *channelQualityRepository) CreateResult(ctx context.Context, result *service.ChannelQualityResult) (*service.ChannelQualityResult, error) {
	out := *result
	err := r.db.QueryRowContext(ctx, `
		INSERT INTO channel_quality_results
		(group_id, channel_id, group_name, channel_name, platform, model, status, message, latency_ms, checked_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		RETURNING id, checked_at`, result.GroupID, result.ChannelID, result.GroupName, result.ChannelName,
		result.Platform, result.Model, result.Status, result.Message, result.LatencyMs, result.CheckedAt).
		Scan(&out.ID, &out.CheckedAt)
	if err != nil {
		return nil, fmt.Errorf("create channel quality result: %w", err)
	}
	return &out, nil
}

func (r *channelQualityRepository) UpdateResult(ctx context.Context, result *service.ChannelQualityResult) error {
	_, err := r.db.ExecContext(ctx, `
		UPDATE channel_quality_results
		SET status=$2, message=$3, latency_ms=$4, checked_at=$5
		WHERE id=$1`, result.ID, result.Status, result.Message, result.LatencyMs, result.CheckedAt)
	if err != nil {
		return fmt.Errorf("update channel quality result: %w", err)
	}
	return nil
}

func (r *channelQualityRepository) ListLatest(ctx context.Context, groupIDs []int64, historyLimit int) ([]*service.ChannelQualityView, error) {
	// nil means an administrator requested all groups; a non-nil empty slice
	// means the user has no permitted groups and should receive no rows.
	if groupIDs != nil && len(groupIDs) == 0 {
		return []*service.ChannelQualityView{}, nil
	}
	if historyLimit <= 0 {
		historyLimit = 100
	}
	var groupFilter any
	if groupIDs != nil {
		groupFilter = pq.Array(groupIDs)
	}
	rows, err := r.db.QueryContext(ctx, `
		WITH ranked AS (
			SELECT r.*, ROW_NUMBER() OVER (PARTITION BY r.group_id ORDER BY r.checked_at DESC) AS rn
			FROM channel_quality_results r
			WHERE ($1::bigint[] IS NULL OR r.group_id = ANY($1))
		)
		SELECT id, group_id, channel_id, group_name, channel_name, platform, model, status, message, latency_ms, checked_at
		FROM ranked WHERE rn <= $2 ORDER BY group_name ASC, checked_at DESC`, groupFilter, historyLimit)
	if err != nil {
		return nil, fmt.Errorf("list channel quality results: %w", err)
	}
	defer rows.Close()
	byGroup := make(map[int64]*service.ChannelQualityView)
	var order []int64
	for rows.Next() {
		var item service.ChannelQualityResult
		if err := rows.Scan(&item.ID, &item.GroupID, &item.ChannelID, &item.GroupName, &item.ChannelName,
			&item.Platform, &item.Model, &item.Status, &item.Message, &item.LatencyMs, &item.CheckedAt); err != nil {
			return nil, err
		}
		view := byGroup[item.GroupID]
		if view == nil {
			view = &service.ChannelQualityView{GroupID: item.GroupID, GroupName: item.GroupName, ChannelName: item.ChannelName,
				ChannelID: item.ChannelID, Platform: item.Platform, Model: item.Model, Timeline: []service.ChannelQualityResult{}}
			byGroup[item.GroupID] = view
			order = append(order, item.GroupID)
		}
		view.Timeline = append(view.Timeline, item)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, groupID := range order {
		view := byGroup[groupID]
		if len(view.Timeline) > 0 {
			latest := view.Timeline[0]
			view.Status, view.Message, view.LatencyMs, view.CheckedAt, view.Model = latest.Status, latest.Message, latest.LatencyMs, &latest.CheckedAt, latest.Model
		}
	}
	result := make([]*service.ChannelQualityView, 0, len(order))
	for _, groupID := range order {
		result = append(result, byGroup[groupID])
	}
	return result, nil
}

func (r *channelQualityRepository) ListHistory(ctx context.Context, groupID int64, limit int) ([]*service.ChannelQualityResult, error) {
	if limit <= 0 || limit > 200 {
		limit = 60
	}
	rows, err := r.db.QueryContext(ctx, `
		SELECT id, group_id, channel_id, group_name, channel_name, platform, model, status, message, latency_ms, checked_at
		FROM channel_quality_results WHERE group_id=$1 ORDER BY checked_at DESC LIMIT $2`, groupID, limit)
	if err != nil {
		return nil, fmt.Errorf("list channel quality history: %w", err)
	}
	defer rows.Close()
	items := make([]*service.ChannelQualityResult, 0)
	for rows.Next() {
		item := &service.ChannelQualityResult{}
		if err := rows.Scan(&item.ID, &item.GroupID, &item.ChannelID, &item.GroupName, &item.ChannelName,
			&item.Platform, &item.Model, &item.Status, &item.Message, &item.LatencyMs, &item.CheckedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}
