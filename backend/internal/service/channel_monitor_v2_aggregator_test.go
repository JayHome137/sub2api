//go:build unit

package service

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type channelMonitorV2AggregatorRepoStub struct {
	ChannelMonitorV2Repository
	watermark *ChannelMonitorV2AggregationWatermark
	ranges    [][2]time.Time
}

func (s *channelMonitorV2AggregatorRepoStub) GetAggregationWatermark(context.Context) (*ChannelMonitorV2AggregationWatermark, error) {
	return s.watermark, nil
}

func (s *channelMonitorV2AggregatorRepoStub) RecomputeRange(_ context.Context, start, end time.Time) error {
	s.ranges = append(s.ranges, [2]time.Time{start, end})
	return nil
}

func TestChannelMonitorV2AggregatorRecoversLiveGapWithinBound(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Minute)
	dataThrough := now.Add(-35 * time.Minute)
	repo := &channelMonitorV2AggregatorRepoStub{
		watermark: &ChannelMonitorV2AggregationWatermark{
			HasData:        true,
			DataThrough:    dataThrough,
			BackfillCursor: now.Add(-100 * 24 * time.Hour),
		},
	}
	aggregator := NewChannelMonitorV2Aggregator(repo, nil, nil)

	aggregator.runOnce()

	require.NotEmpty(t, repo.ranges)
	require.Equal(t, dataThrough, repo.ranges[0][0])
	require.WithinDuration(t, now, repo.ranges[0][1], time.Minute)
	require.Len(t, repo.ranges, 1, "live recovery must not move the historical backfill cursor")
}

func TestChannelMonitorV2AggregatorCapsLiveGapRecovery(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Minute)
	repo := &channelMonitorV2AggregatorRepoStub{
		watermark: &ChannelMonitorV2AggregationWatermark{
			HasData:        true,
			DataThrough:    now.Add(-24 * time.Hour),
			BackfillCursor: now.Add(-100 * 24 * time.Hour),
		},
	}
	aggregator := NewChannelMonitorV2Aggregator(repo, nil, nil)

	aggregator.runOnce()

	require.NotEmpty(t, repo.ranges)
	require.WithinDuration(t, now.Add(-channelMonitorV2LiveMaxCatchUp), repo.ranges[0][0], time.Minute)
	require.WithinDuration(t, now, repo.ranges[0][1], time.Minute)
	require.Len(t, repo.ranges, 1, "bounded live recovery must leave older history to backfill")
}

func TestChannelMonitorV2MaxChunkForDepth(t *testing.T) {
	now := time.Date(2026, 8, 8, 12, 0, 0, 0, time.UTC)

	// Within last day → tightest ceiling (2h).
	require.Equal(t, channelMonitorV2MaxChunkNear1d, channelMonitorV2MaxChunkForDepth(now, now.Add(-2*time.Hour)))
	// Between 1d and 7d → 4h.
	require.Equal(t, channelMonitorV2MaxChunkNear7d, channelMonitorV2MaxChunkForDepth(now, now.Add(-2*24*time.Hour)))
	// Older than 7d → 6h (never 24h default).
	require.Equal(t, channelMonitorV2MaxChunkFar, channelMonitorV2MaxChunkForDepth(now, now.Add(-10*24*time.Hour)))
	require.Less(t, channelMonitorV2MaxChunkFar, 24*time.Hour)
	require.Equal(t, time.Hour, channelMonitorV2BackfillChunkInit)
	require.Equal(t, 15*time.Minute, channelMonitorV2MinBackfillChunk)
}

func TestChannelMonitorV2AggregatorAdaptiveChunk(t *testing.T) {
	s := NewChannelMonitorV2Aggregator(nil, nil, nil)
	now := time.Date(2026, 8, 8, 12, 0, 0, 0, time.UTC)
	cursor := now.Add(-3 * time.Hour)

	// Failure shrinks chunk and sets backoff floor.
	s.backfillChunk = 2 * time.Hour
	s.recordBackfillFailure(now, cursor)
	require.Equal(t, time.Hour, s.backfillChunk)
	require.Equal(t, time.Minute, s.nextWaitFloor)
	require.Equal(t, 1, s.backfillFailures)

	// Repeated failure halves again and raises floor.
	s.recordBackfillFailure(now, cursor)
	require.Equal(t, 30*time.Minute, s.backfillChunk)
	require.Equal(t, 2*time.Minute, s.nextWaitFloor)

	// Fast success grows within depth ceiling and clears backoff.
	s.recordBackfillSuccess(cursor.Add(-30*time.Minute), 5*time.Second, now)
	require.Equal(t, 0, s.backfillFailures)
	require.Equal(t, time.Duration(0), s.nextWaitFloor)
	require.Greater(t, s.backfillChunk, 30*time.Minute)
	require.LessOrEqual(t, s.backfillChunk, channelMonitorV2MaxChunkForDepth(now, cursor.Add(-30*time.Minute)))
}
