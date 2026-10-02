//go:build unit

package service

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

var _ OpsRepository = (*stubOpsRepo)(nil)

type stubOpsRepo struct {
	OpsRepository
	overview *OpsDashboardOverview
	billing  *BillingAnomalySnapshot
	err      error
}

func (s *stubOpsRepo) GetDashboardOverview(ctx context.Context, filter *OpsDashboardFilter) (*OpsDashboardOverview, error) {
	if s.err != nil {
		return nil, s.err
	}
	if s.overview != nil {
		return s.overview, nil
	}
	return &OpsDashboardOverview{}, nil
}

func (s *stubOpsRepo) GetBillingAnomalySnapshot(context.Context, time.Time, time.Time) (*BillingAnomalySnapshot, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.billing, nil
}

func TestComputeGroupAvailableRatio(t *testing.T) {
	t.Parallel()

	t.Run("正常情况: 10个账号, 8个可用 = 80%", func(t *testing.T) {
		t.Parallel()

		got := computeGroupAvailableRatio(&GroupAvailability{
			TotalAccounts:  10,
			AvailableCount: 8,
		})
		require.InDelta(t, 80.0, got, 0.0001)
	})

	t.Run("边界情况: TotalAccounts = 0 应返回 0", func(t *testing.T) {
		t.Parallel()

		got := computeGroupAvailableRatio(&GroupAvailability{
			TotalAccounts:  0,
			AvailableCount: 8,
		})
		require.Equal(t, 0.0, got)
	})

	t.Run("边界情况: AvailableCount = 0 应返回 0%", func(t *testing.T) {
		t.Parallel()

		got := computeGroupAvailableRatio(&GroupAvailability{
			TotalAccounts:  10,
			AvailableCount: 0,
		})
		require.Equal(t, 0.0, got)
	})
}

func TestCountAccountsByCondition(t *testing.T) {
	t.Parallel()

	t.Run("测试限流账号统计: acc.IsRateLimited", func(t *testing.T) {
		t.Parallel()

		accounts := map[int64]*AccountAvailability{
			1: {IsRateLimited: true},
			2: {IsRateLimited: false},
			3: {IsRateLimited: true},
		}

		got := countAccountsByCondition(accounts, func(acc *AccountAvailability) bool {
			return acc.IsRateLimited
		})
		require.Equal(t, int64(2), got)
	})

	t.Run("测试错误账号统计（排除临时不可调度）: acc.HasError && acc.TempUnschedulableUntil == nil", func(t *testing.T) {
		t.Parallel()

		until := time.Now().UTC().Add(5 * time.Minute)
		accounts := map[int64]*AccountAvailability{
			1: {HasError: true},
			2: {HasError: true, TempUnschedulableUntil: &until},
			3: {HasError: false},
		}

		got := countAccountsByCondition(accounts, func(acc *AccountAvailability) bool {
			return acc.HasError && acc.TempUnschedulableUntil == nil
		})
		require.Equal(t, int64(1), got)
	})

	t.Run("边界情况: 空 map 应返回 0", func(t *testing.T) {
		t.Parallel()

		got := countAccountsByCondition(map[int64]*AccountAvailability{}, func(acc *AccountAvailability) bool {
			return acc.IsRateLimited
		})
		require.Equal(t, int64(0), got)
	})
}

// TestComputeRuleMetric_AccountTempUnscheduledCount verifies the new
// account_temp_unscheduled_count metric counts accounts currently in the
// temp-unscheduled window and ignores those whose window has expired or
// were never temp-unscheduled.
func TestComputeRuleMetric_AccountTempUnscheduledCount(t *testing.T) {
	t.Parallel()

	now := time.Now().UTC()
	futureUntil := now.Add(5 * time.Minute)
	pastUntil := now.Add(-1 * time.Minute)

	availability := &OpsAccountAvailability{
		Accounts: map[int64]*AccountAvailability{
			// currently temp-unscheduled (window active)
			1: {TempUnschedulableUntil: &futureUntil},
			2: {TempUnschedulableUntil: &futureUntil},
			// temp-unsched window already expired → should NOT count
			3: {TempUnschedulableUntil: &pastUntil},
			// never temp-unscheduled
			4: {HasError: true},
			5: {IsRateLimited: true},
		},
	}

	opsService := &OpsService{
		getAccountAvailability: func(_ context.Context, _ string, _ *int64) (*OpsAccountAvailability, error) {
			return availability, nil
		},
	}
	svc := &OpsAlertEvaluatorService{
		opsService: opsService,
		opsRepo:    &stubOpsRepo{},
	}

	rule := &OpsAlertRule{MetricType: "account_temp_unscheduled_count"}
	val, ok := svc.computeRuleMetric(context.Background(), rule, nil,
		now.Add(-5*time.Minute), now, "", nil)

	require.True(t, ok)
	require.InDelta(t, 2.0, val, 0.0001, "only 2 accounts have an active temp-unsched window")
}

func TestComputeRuleMetricNewIndicators(t *testing.T) {
	t.Parallel()

	groupID := int64(101)
	platform := "openai"

	availability := &OpsAccountAvailability{
		Group: &GroupAvailability{
			GroupID:        groupID,
			TotalAccounts:  10,
			AvailableCount: 8,
		},
		Accounts: map[int64]*AccountAvailability{
			1: {IsRateLimited: true},
			2: {IsRateLimited: true},
			3: {HasError: true},
			4: {HasError: true, TempUnschedulableUntil: timePtr(time.Now().UTC().Add(2 * time.Minute))},
			5: {HasError: false, IsRateLimited: false},
		},
	}

	opsService := &OpsService{
		getAccountAvailability: func(_ context.Context, _ string, _ *int64) (*OpsAccountAvailability, error) {
			return availability, nil
		},
	}

	svc := &OpsAlertEvaluatorService{
		opsService: opsService,
		opsRepo:    &stubOpsRepo{overview: &OpsDashboardOverview{}},
	}

	start := time.Now().UTC().Add(-5 * time.Minute)
	end := time.Now().UTC()
	ctx := context.Background()

	tests := []struct {
		name       string
		metricType string
		groupID    *int64
		wantValue  float64
		wantOK     bool
	}{
		{
			name:       "group_available_accounts",
			metricType: "group_available_accounts",
			groupID:    &groupID,
			wantValue:  8,
			wantOK:     true,
		},
		{
			name:       "group_available_ratio",
			metricType: "group_available_ratio",
			groupID:    &groupID,
			wantValue:  80.0,
			wantOK:     true,
		},
		{
			name:       "account_rate_limited_count",
			metricType: "account_rate_limited_count",
			groupID:    nil,
			wantValue:  2,
			wantOK:     true,
		},
		{
			name:       "account_error_count",
			metricType: "account_error_count",
			groupID:    nil,
			wantValue:  1,
			wantOK:     true,
		},
		{
			name:       "group_available_accounts without group_id returns false",
			metricType: "group_available_accounts",
			groupID:    nil,
			wantValue:  0,
			wantOK:     false,
		},
		{
			name:       "group_available_ratio without group_id returns false",
			metricType: "group_available_ratio",
			groupID:    nil,
			wantValue:  0,
			wantOK:     false,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			rule := &OpsAlertRule{
				MetricType: tt.metricType,
			}
			gotValue, gotOK := svc.computeRuleMetric(ctx, rule, nil, start, end, platform, tt.groupID)
			require.Equal(t, tt.wantOK, gotOK)
			if !tt.wantOK {
				return
			}
			require.InDelta(t, tt.wantValue, gotValue, 0.0001)
		})
	}
}

func TestComputeRuleMetricLatencyPercentiles(t *testing.T) {
	t.Parallel()

	p95 := 2400
	p99 := 4100
	svc := &OpsAlertEvaluatorService{
		opsRepo: &stubOpsRepo{overview: &OpsDashboardOverview{
			Duration: OpsPercentiles{P95: &p95, P99: &p99},
		}},
	}
	start := time.Now().UTC().Add(-5 * time.Minute)
	end := time.Now().UTC()

	for _, tc := range []struct {
		metric string
		want   float64
	}{
		{metric: "p95_latency_ms", want: 2400},
		{metric: "p99_latency_ms", want: 4100},
	} {
		t.Run(tc.metric, func(t *testing.T) {
			t.Parallel()
			value, ok := svc.computeRuleMetric(context.Background(), &OpsAlertRule{MetricType: tc.metric}, nil, start, end, "", nil)
			require.True(t, ok)
			require.Equal(t, tc.want, value)
		})
	}

	t.Run("missing percentile is unavailable", func(t *testing.T) {
		t.Parallel()
		svc := &OpsAlertEvaluatorService{opsRepo: &stubOpsRepo{overview: &OpsDashboardOverview{}}}
		value, ok := svc.computeRuleMetric(context.Background(), &OpsAlertRule{MetricType: "p95_latency_ms"}, nil, start, end, "", nil)
		require.False(t, ok)
		require.Zero(t, value)
	})
}

func TestBillingAnomalySnapshotRatios(t *testing.T) {
	t.Parallel()

	snapshot := &BillingAnomalySnapshot{
		MeteredRequests:                200,
		ZeroCostRequests:               12,
		PreviousWindowZeroCostRequests: 5,
		WindowCostUSD:                  30,
		PreviousWindowCostUSD:          20,
	}
	require.InDelta(t, 6, snapshot.ZeroCostRatio(), 0.0001)
	require.Equal(t, float64(7), snapshot.ZeroCostRequestDelta())
	spike, ok := snapshot.CostSpikeRatio()
	require.True(t, ok)
	require.InDelta(t, 150, spike, 0.0001)

	snapshot.MeteredRequests = 0
	require.Zero(t, snapshot.ZeroCostRatio())
	_, ok = (&BillingAnomalySnapshot{WindowCostUSD: 3}).CostSpikeRatio()
	require.False(t, ok, "a missing previous-window baseline must not alert")
}

func TestComputeBillingAnomalyMetrics(t *testing.T) {
	t.Parallel()

	svc := &OpsAlertEvaluatorService{opsRepo: &stubOpsRepo{billing: &BillingAnomalySnapshot{
		MeteredRequests:                100,
		ZeroCostRequests:               4,
		PreviousWindowZeroCostRequests: 1,
		WindowCostUSD:                  6,
		PreviousWindowCostUSD:          3,
		NegativeBalanceUsers:           2,
	}}}
	start := time.Now().UTC().Add(-5 * time.Minute)
	end := time.Now().UTC()
	for _, tc := range []struct {
		metric string
		want   float64
	}{
		{OpsMetricBillingZeroCostRequests, 4},
		{OpsMetricBillingZeroCostRatio, 4},
		{OpsMetricBillingZeroCostRequestsDelta, 3},
		{OpsMetricBillingCostSpikeRatio, 200},
		{OpsMetricBillingNegativeBalanceUsers, 2},
	} {
		t.Run(tc.metric, func(t *testing.T) {
			value, ok := svc.computeRuleMetric(context.Background(), &OpsAlertRule{MetricType: tc.metric}, nil, start, end, "", nil)
			require.True(t, ok)
			require.Equal(t, tc.want, value)
		})
	}
}
