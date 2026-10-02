package repository

import (
	"context"
	"fmt"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

// GetBillingAnomalySnapshot only reads usage and user balance aggregates.
func (r *opsRepository) GetBillingAnomalySnapshot(ctx context.Context, start, end time.Time) (*service.BillingAnomalySnapshot, error) {
	if r == nil || r.db == nil {
		return nil, fmt.Errorf("nil ops repository")
	}
	if !end.After(start) {
		return nil, fmt.Errorf("invalid billing anomaly window")
	}
	window := end.Sub(start)
	previousStart := start.Add(-window)
	snapshot := &service.BillingAnomalySnapshot{}

	const usageQuery = `
SELECT
  COUNT(*) FILTER (
    WHERE created_at >= $1 AND created_at < $2
      AND (input_tokens > 0 OR output_tokens > 0 OR cache_creation_tokens > 0 OR cache_read_tokens > 0)
  ),
  COUNT(*) FILTER (
    WHERE created_at >= $1 AND created_at < $2
      AND (input_tokens > 0 OR output_tokens > 0 OR cache_creation_tokens > 0 OR cache_read_tokens > 0)
      AND actual_cost = 0
  ),
  COUNT(*) FILTER (
    WHERE created_at >= $3 AND created_at < $1
      AND (input_tokens > 0 OR output_tokens > 0 OR cache_creation_tokens > 0 OR cache_read_tokens > 0)
      AND actual_cost = 0
  ),
  COALESCE(SUM(actual_cost) FILTER (WHERE created_at >= $1 AND created_at < $2), 0),
  COALESCE(SUM(actual_cost) FILTER (WHERE created_at >= $3 AND created_at < $1), 0)
FROM usage_logs
WHERE created_at >= $3 AND created_at < $2`
	if err := r.db.QueryRowContext(ctx, usageQuery, start, end, previousStart).Scan(
		&snapshot.MeteredRequests,
		&snapshot.ZeroCostRequests,
		&snapshot.PreviousWindowZeroCostRequests,
		&snapshot.WindowCostUSD,
		&snapshot.PreviousWindowCostUSD,
	); err != nil {
		return nil, fmt.Errorf("query billing usage anomalies: %w", err)
	}

	if err := r.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE balance < 0 AND deleted_at IS NULL`).Scan(&snapshot.NegativeBalanceUsers); err != nil {
		return nil, fmt.Errorf("query negative balance users: %w", err)
	}
	return snapshot, nil
}
