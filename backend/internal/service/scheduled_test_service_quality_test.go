package service

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"testing"
)

type scheduledPlanLifecycleRepoStub struct {
	ScheduledTestPlanRepository
	plan       *ScheduledTestPlan
	deleteErr  error
	clearCalls int
}

func (r *scheduledPlanLifecycleRepoStub) GetByID(context.Context, int64) (*ScheduledTestPlan, error) {
	if r.plan == nil {
		return nil, errors.New("plan not found")
	}
	copy := *r.plan
	return &copy, nil
}

func (r *scheduledPlanLifecycleRepoStub) Update(_ context.Context, plan *ScheduledTestPlan) (*ScheduledTestPlan, error) {
	copy := *plan
	r.plan = &copy
	return &copy, nil
}

func (r *scheduledPlanLifecycleRepoStub) Delete(context.Context, int64) error {
	if r.deleteErr != nil {
		return r.deleteErr
	}
	r.plan = nil
	return nil
}

type scheduledPlanPauseCleanupStub struct {
	AccountRepository
	planIDs []int64
	err     error
}

func (r *scheduledPlanPauseCleanupStub) ClearScheduledQualityPauseByPlan(_ context.Context, planID int64) error {
	r.planIDs = append(r.planIDs, planID)
	return r.err
}

func TestScheduledTestServiceUpdateClearsPauseWhenPromptBecomesCustom(t *testing.T) {
	plans := &scheduledPlanLifecycleRepoStub{plan: &ScheduledTestPlan{
		ID:                  10,
		AccountID:           20,
		PromptText:          DefaultScheduledTestPrompt,
		CronExpression:      DefaultScheduledTestCron,
		Enabled:             true,
		QualityCheckEnabled: true,
		MaxResults:          50,
	}}
	cleanup := &scheduledPlanPauseCleanupStub{err: errors.New("database unavailable")}
	svc := NewScheduledTestService(plans, nil, cleanup)
	updated := *plans.plan
	updated.PromptText = "Return the current balance as a number."

	if _, err := svc.UpdatePlan(context.Background(), &updated); err == nil {
		t.Fatal("first update should report the pause cleanup failure")
	}
	cleanup.err = nil
	updated = *plans.plan
	if _, err := svc.UpdatePlan(context.Background(), &updated); err != nil {
		t.Fatalf("retry update: %v", err)
	}
	if len(cleanup.planIDs) != 2 || cleanup.planIDs[0] != plans.plan.ID || cleanup.planIDs[1] != plans.plan.ID {
		t.Fatalf("cleanup plan IDs=%v, want [%d %d]", cleanup.planIDs, plans.plan.ID, plans.plan.ID)
	}
}

func TestScheduledTestServiceDeleteRetriesPauseCleanupAfterPlanIsGone(t *testing.T) {
	plans := &scheduledPlanLifecycleRepoStub{plan: &ScheduledTestPlan{ID: 11}}
	cleanup := &scheduledPlanPauseCleanupStub{err: errors.New("database unavailable")}
	svc := NewScheduledTestService(plans, nil, cleanup)

	if err := svc.DeletePlan(context.Background(), 11); err == nil {
		t.Fatal("first delete should report the pause cleanup failure")
	}
	cleanup.err = nil
	if err := svc.DeletePlan(context.Background(), 11); err != nil {
		t.Fatalf("retry delete: %v", err)
	}
	if len(cleanup.planIDs) != 2 || cleanup.planIDs[0] != 11 || cleanup.planIDs[1] != 11 {
		t.Fatalf("cleanup plan IDs=%v, want [11 11]", cleanup.planIDs)
	}
}

func TestScheduledTestQualityPromptsMatchMigrationBackfill(t *testing.T) {
	wantHashes := map[string]struct{}{
		"15caede62ffea7c47ee2ccf2c8674e87": {},
		"297caf9418b914f791fe7df9ef44f58e": {},
	}
	for _, prompt := range ScheduledTestQualityPrompts() {
		sum := md5.Sum([]byte(prompt))
		delete(wantHashes, hex.EncodeToString(sum[:]))
		if !isDefaultScheduledTestPrompt(prompt) {
			t.Errorf("migration prompt is not recognized by the evaluator")
		}
	}
	if len(wantHashes) != 0 {
		t.Errorf("migration prompt hashes not represented in evaluator: %v", wantHashes)
	}
}
