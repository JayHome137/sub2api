package service

import (
	"context"
	"github.com/stretchr/testify/require"
	"testing"
	"time"
)

type baselineOverviewRepo struct{ opsRepoMock }

func (*baselineOverviewRepo) GetDashboardOverview(context.Context, *OpsDashboardFilter) (*OpsDashboardOverview, error) {
	return &OpsDashboardOverview{RequestCountTotal: 10, TTFT: OpsPercentiles{P99: intPtr(40000)}}, nil
}
func TestDashboardHealthReadsSavedTTFTBaseline(t *testing.T) {
	settings := newRuntimeSettingRepoStub()
	svc := &OpsService{opsRepo: &baselineOverviewRepo{}, settingRepo: settings}
	filter := &OpsDashboardFilter{StartTime: time.Now().Add(-time.Hour), EndTime: time.Now(), QueryMode: OpsQueryModeRaw}
	settings.values[SettingKeyOpsMetricThresholds] = `{"ttft_p99_ms_max":30000}`
	first, err := svc.GetDashboardOverview(context.Background(), filter)
	require.NoError(t, err)
	require.Equal(t, 30000.0, first.TTFTHealthBaselineMs)
	require.Equal(t, 94, first.HealthScore)
	settings.values[SettingKeyOpsMetricThresholds] = `{"ttft_p99_ms_max":50000}`
	second, err := svc.GetDashboardOverview(context.Background(), filter)
	require.NoError(t, err)
	require.Equal(t, 50000.0, second.TTFTHealthBaselineMs)
	require.Equal(t, 100, second.HealthScore)
	require.Zero(t, settings.setCalls, "must not overwrite saved settings")
}
