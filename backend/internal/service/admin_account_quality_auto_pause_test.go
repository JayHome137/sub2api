package service

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
)

type scheduledQualityAutoPauseAccountRepoStub struct {
	AccountRepository
	updated map[string]any
	cleared []int64
}

func (r *scheduledQualityAutoPauseAccountRepoStub) UpdateExtra(_ context.Context, _ int64, updates map[string]any) error {
	r.updated = updates
	return nil
}

func (r *scheduledQualityAutoPauseAccountRepoStub) ClearScheduledQualityPause(_ context.Context, accountID, planID int64) (bool, error) {
	r.cleared = []int64{accountID, planID}
	return true, nil
}

func TestUpdateAccountExtraDisablingScheduledQualityAutoPauseClearsOwnedPause(t *testing.T) {
	repo := &scheduledQualityAutoPauseAccountRepoStub{}
	svc := &adminServiceImpl{accountRepo: repo}

	err := svc.UpdateAccountExtra(context.Background(), 27, map[string]any{ScheduledQualityAutoPauseEnabledExtraKey: false})

	require.NoError(t, err)
	require.Equal(t, map[string]any{ScheduledQualityAutoPauseEnabledExtraKey: false}, repo.updated)
	require.Equal(t, []int64{27, 0}, repo.cleared)
}

func TestUpdateAccountExtraEnablingScheduledQualityAutoPauseDoesNotClearPause(t *testing.T) {
	repo := &scheduledQualityAutoPauseAccountRepoStub{}
	svc := &adminServiceImpl{accountRepo: repo}

	err := svc.UpdateAccountExtra(context.Background(), 28, map[string]any{ScheduledQualityAutoPauseEnabledExtraKey: true})

	require.NoError(t, err)
	require.Empty(t, repo.cleared)
}
