package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type scheduledQualityResultRepoStub struct {
	results []*ScheduledTestResult
}

func (r *scheduledQualityResultRepoStub) Create(_ context.Context, result *ScheduledTestResult) (*ScheduledTestResult, error) {
	return result, nil
}

func (r *scheduledQualityResultRepoStub) ListByPlanID(_ context.Context, _ int64, _ int) ([]*ScheduledTestResult, error) {
	return r.results, nil
}

func (r *scheduledQualityResultRepoStub) PruneOldResults(context.Context, int64, int) error {
	return nil
}

type scheduledQualityAccountRepoStub struct {
	AccountRepository
	account       *Account
	groupAccounts map[int64][]Account
	groupErrors   map[int64]error
	markCalls     int
	clearCalls    int
}

func (r *scheduledQualityAccountRepoStub) GetByID(context.Context, int64) (*Account, error) {
	if r.account == nil {
		return nil, errors.New("account missing")
	}
	return r.account, nil
}

func (r *scheduledQualityAccountRepoStub) ListSchedulableByGroupID(_ context.Context, groupID int64) ([]Account, error) {
	if err := r.groupErrors[groupID]; err != nil {
		return nil, err
	}
	return r.groupAccounts[groupID], nil
}

func (r *scheduledQualityAccountRepoStub) SetSchedulable(_ context.Context, _ int64, schedulable bool) error {
	r.account.Schedulable = schedulable
	return nil
}

func (r *scheduledQualityAccountRepoStub) SetTempUnschedulable(_ context.Context, _ int64, _ time.Time, reason string) error {
	r.account.TempUnschedulableReason = reason
	return nil
}

func (r *scheduledQualityAccountRepoStub) ClearTempUnschedulable(_ context.Context, _ int64) error {
	r.account.TempUnschedulableReason = ""
	return nil
}

func (r *scheduledQualityAccountRepoStub) MarkScheduledQualityPause(_ context.Context, _ int64, _ int64, _ string, groupIDs []int64, reason string) (bool, error) {
	if !r.account.Schedulable {
		return false, nil
	}
	if len(groupIDs) == 0 {
		return false, nil
	}
	for _, groupID := range groupIDs {
		if err := r.groupErrors[groupID]; err != nil || len(r.groupAccounts[groupID]) <= 1 {
			return false, nil
		}
	}
	r.markCalls++
	r.account.Schedulable = false
	r.account.TempUnschedulableReason = reason
	return true, nil
}

func (r *scheduledQualityAccountRepoStub) ClearScheduledQualityPause(_ context.Context, _ int64, planID int64) (bool, error) {
	prefix := scheduledQualityReasonPrefix
	if planID > 0 {
		prefix = fmt.Sprintf("%s plan=%d:", prefix, planID)
	}
	if !strings.HasPrefix(r.account.TempUnschedulableReason, prefix) {
		return false, nil
	}
	r.clearCalls++
	r.account.Schedulable = true
	r.account.TempUnschedulableReason = ""
	return true, nil
}

func newScheduledQualityRunner(t *testing.T, repo *scheduledQualityAccountRepoStub, results []*ScheduledTestResult) *ScheduledTestRunnerService {
	t.Helper()
	resultRepo := &scheduledQualityResultRepoStub{results: results}
	scheduledSvc := NewScheduledTestService(nil, resultRepo)
	return &ScheduledTestRunnerService{
		scheduledSvc:   scheduledSvc,
		accountTestSvc: &AccountTestService{accountRepo: repo},
	}
}

func degradedResults() []*ScheduledTestResult {
	return []*ScheduledTestResult{{Status: "degraded"}, {Status: "degraded"}}
}

func TestScheduledQualityRunnerPausesOnlyWhenCapacityAllows(t *testing.T) {
	tests := []struct {
		name       string
		account    Account
		groups     map[int64][]Account
		groupErrs  map[int64]error
		markCalls  int
		wantPaused bool
	}{
		{
			name:       "ungrouped account",
			account:    Account{ID: 1, Schedulable: true},
			wantPaused: false,
		},
		{
			name:       "upstream account is never paused",
			account:    Account{ID: 2, Type: AccountTypeUpstream, Schedulable: true},
			wantPaused: false,
		},
		{
			name:       "single account group stays available",
			account:    Account{ID: 3, GroupIDs: []int64{10}, Schedulable: true},
			groups:     map[int64][]Account{10: {{ID: 3}}},
			wantPaused: false,
		},
		{
			name:       "multi account group may pause",
			account:    Account{ID: 4, GroupIDs: []int64{11}, Schedulable: true},
			groups:     map[int64][]Account{11: {{ID: 4}, {ID: 5}}},
			wantPaused: true,
		},
		{
			name:       "any single account group blocks pause",
			account:    Account{ID: 5, GroupIDs: []int64{12, 13}, Schedulable: true},
			groups:     map[int64][]Account{12: {{ID: 5}, {ID: 6}}, 13: {{ID: 5}}},
			wantPaused: false,
		},
		{
			name:       "capacity lookup failure is fail open",
			account:    Account{ID: 6, GroupIDs: []int64{14}, Schedulable: true},
			groups:     map[int64][]Account{14: {{ID: 6}, {ID: 7}}},
			groupErrs:  map[int64]error{14: errors.New("database unavailable")},
			wantPaused: false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := &scheduledQualityAccountRepoStub{
				account:       &tc.account,
				groupAccounts: tc.groups,
				groupErrors:   tc.groupErrs,
			}
			runner := newScheduledQualityRunner(t, repo, degradedResults())
			runner.updateQualityScheduling(context.Background(), &ScheduledTestPlan{ID: 20, AccountID: tc.account.ID}, &ScheduledTestResult{Status: "degraded", ErrorMessage: "bad quality"})
			if got := !repo.account.Schedulable; got != tc.wantPaused {
				t.Fatalf("paused=%v, want %v", got, tc.wantPaused)
			}
			if tc.wantPaused && repo.markCalls != 1 {
				t.Fatalf("mark calls=%d, want 1", repo.markCalls)
			}
		})
	}
}

func TestScheduledQualityRunnerDoesNotClaimAlreadyPausedAccount(t *testing.T) {
	repo := &scheduledQualityAccountRepoStub{account: &Account{
		ID:                      31,
		Schedulable:             false,
		TempUnschedulableReason: "manual pause",
	}}
	runner := newScheduledQualityRunner(t, repo, degradedResults())
	runner.updateQualityScheduling(context.Background(), &ScheduledTestPlan{ID: 21, AccountID: 31}, &ScheduledTestResult{Status: "degraded"})
	if repo.markCalls != 0 {
		t.Fatalf("mark calls=%d, want 0", repo.markCalls)
	}
	if repo.account.TempUnschedulableReason != "manual pause" {
		t.Fatalf("pause reason was overwritten: %q", repo.account.TempUnschedulableReason)
	}
}

func TestScheduledQualityRunnerRecoversOnlyQualityPause(t *testing.T) {
	tests := []struct {
		name        string
		reason      string
		wantCleared bool
		wantSched   bool
	}{
		{name: "quality pause", reason: scheduledQualityReasonPrefix + " plan=22: degraded", wantCleared: true, wantSched: true},
		{name: "another plan owns the pause", reason: scheduledQualityReasonPrefix + " plan=1: degraded", wantCleared: false, wantSched: false},
		{name: "manual pause", reason: "operator pause", wantCleared: false, wantSched: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			repo := &scheduledQualityAccountRepoStub{account: &Account{ID: 41, Schedulable: false, TempUnschedulableReason: tc.reason}}
			runner := newScheduledQualityRunner(t, repo, nil)
			runner.updateQualityScheduling(context.Background(), &ScheduledTestPlan{ID: 22, AccountID: 41}, &ScheduledTestResult{Status: "success"})
			if (repo.clearCalls > 0) != tc.wantCleared {
				t.Fatalf("clear calls=%d, want cleared=%v", repo.clearCalls, tc.wantCleared)
			}
			if repo.account.Schedulable != tc.wantSched {
				t.Fatalf("schedulable=%v, want %v", repo.account.Schedulable, tc.wantSched)
			}
		})
	}
}

func TestHasConsecutiveDegradedResults(t *testing.T) {
	if !hasConsecutiveDegradedResults(degradedResults()) {
		t.Fatal("two degraded results should satisfy the guard")
	}
	if hasConsecutiveDegradedResults([]*ScheduledTestResult{{Status: "degraded"}, {Status: "success"}}) {
		t.Fatal("a success between degraded results must reset the guard")
	}
}
