package service

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/logger"
	"github.com/google/uuid"
	"github.com/robfig/cron/v3"
)

const scheduledTestDefaultMaxWorkers = 10

const (
	scheduledTestRunnerLeaderLockKey = "scheduled-test-runner"
	scheduledTestRunnerLeaderLockTTL = 10 * time.Minute
)

// ScheduledTestRunnerService periodically scans due test plans and executes them.
type ScheduledTestRunnerService struct {
	planRepo       ScheduledTestPlanRepository
	scheduledSvc   *ScheduledTestService
	accountTestSvc *AccountTestService
	rateLimitSvc   *RateLimitService
	cfg            *config.Config
	lockCache      LeaderLockCache
	db             *sql.DB
	instanceID     string
	runMu          sync.Mutex

	cron      *cron.Cron
	startOnce sync.Once
	stopOnce  sync.Once
}

// scheduledQualityPauseRepository keeps quality pause ownership and capacity
// checks inside the concrete repository's atomic database operations.
type scheduledQualityPauseRepository interface {
	MarkScheduledQualityPause(ctx context.Context, planID, id int64, prompt string, groupIDs []int64, reason string) (bool, error)
	ClearScheduledQualityPause(ctx context.Context, id, planID int64) (bool, error)
}

// NewScheduledTestRunnerService creates a new runner.
func NewScheduledTestRunnerService(
	planRepo ScheduledTestPlanRepository,
	scheduledSvc *ScheduledTestService,
	accountTestSvc *AccountTestService,
	rateLimitSvc *RateLimitService,
	cfg *config.Config,
) *ScheduledTestRunnerService {
	return &ScheduledTestRunnerService{
		planRepo:       planRepo,
		scheduledSvc:   scheduledSvc,
		accountTestSvc: accountTestSvc,
		rateLimitSvc:   rateLimitSvc,
		cfg:            cfg,
		instanceID:     uuid.NewString(),
	}
}

// SetLeaderLock wires the shared Redis/PostgreSQL coordination used to keep
// multiple API instances from running the same scheduled-test tick.
func (s *ScheduledTestRunnerService) SetLeaderLock(lockCache LeaderLockCache, db *sql.DB) {
	if s == nil {
		return
	}
	s.lockCache = lockCache
	s.db = db
}

// Start begins the cron ticker (every minute).
func (s *ScheduledTestRunnerService) Start() {
	if s == nil {
		return
	}
	s.startOnce.Do(func() {
		loc := time.Local
		if s.cfg != nil {
			if parsed, err := time.LoadLocation(s.cfg.Timezone); err == nil && parsed != nil {
				loc = parsed
			}
		}

		c := cron.New(cron.WithParser(scheduledTestCronParser), cron.WithLocation(loc))
		_, err := c.AddFunc("* * * * *", func() { s.runScheduled() })
		if err != nil {
			logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] not started (invalid schedule): %v", err)
			return
		}
		s.cron = c
		s.cron.Start()
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] started (tick=every minute)")
	})
}

// Stop gracefully shuts down the cron scheduler.
func (s *ScheduledTestRunnerService) Stop() {
	if s == nil {
		return
	}
	s.stopOnce.Do(func() {
		if s.cron != nil {
			ctx := s.cron.Stop()
			select {
			case <-ctx.Done():
			case <-time.After(3 * time.Second):
				logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] cron stop timed out")
			}
		}
	})
}

func (s *ScheduledTestRunnerService) runScheduled() {
	if s == nil || !s.runMu.TryLock() {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] tick skipped: previous tick still running")
		return
	}
	defer s.runMu.Unlock()
	lockCtx, cancelLock := context.WithTimeout(context.Background(), 2*time.Second)
	release, acquired := tryAcquireSingletonLeaderLock(lockCtx, s.lockCache, s.db, scheduledTestRunnerLeaderLockKey, s.instanceID, scheduledTestRunnerLeaderLockTTL)
	cancelLock()
	if !acquired {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] tick skipped: another instance is running")
		return
	}
	defer release()

	// Delay 10s so execution lands at ~:10 of each minute instead of :00.
	time.Sleep(10 * time.Second)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	now := time.Now()
	plans, err := s.planRepo.ListDue(ctx, now)
	if err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] ListDue error: %v", err)
		return
	}
	if len(plans) == 0 {
		return
	}

	logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] found %d due plans", len(plans))

	sem := make(chan struct{}, scheduledTestDefaultMaxWorkers)
	var wg sync.WaitGroup

	for _, plan := range plans {
		sem <- struct{}{}
		wg.Add(1)
		go func(p *ScheduledTestPlan) {
			defer wg.Done()
			defer func() { <-sem }()
			s.runOnePlan(ctx, p)
		}(plan)
	}

	wg.Wait()
}

func (s *ScheduledTestRunnerService) runOnePlan(ctx context.Context, plan *ScheduledTestPlan) {
	if s == nil || plan == nil || s.accountTestSvc == nil {
		return
	}
	nextRun, claimed := s.claimScheduledPlan(ctx, plan)
	if !claimed {
		return
	}

	var (
		result *ScheduledTestResult
		err    error
	)
	if plan.QualityCheckEnabled {
		result, err = s.accountTestSvc.RunTestBackground(ctx, plan.AccountID, plan.ModelID, plan.PromptText)
	} else {
		result, err = s.accountTestSvc.RunTestBackground(ctx, plan.AccountID, plan.ModelID)
	}
	if err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d RunTestBackground error: %v", plan.ID, err)
		if plan.QualityCheckEnabled {
			s.saveInconclusiveResult(ctx, plan, "quality check inconclusive: scheduled test did not return a result")
		}
		s.finishScheduledPlan(ctx, plan, nextRun)
		return
	}
	if result == nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d RunTestBackground returned no result", plan.ID)
		if plan.QualityCheckEnabled {
			s.saveInconclusiveResult(ctx, plan, "quality check inconclusive: scheduled test returned no result")
		}
		s.finishScheduledPlan(ctx, plan, nextRun)
		return
	}

	if plan.QualityCheckEnabled && result.Status == "success" {
		status, reason := s.accountTestSvc.assessScheduledQuality(ctx, plan, result.ResponseText)
		switch status {
		case "degraded":
			result.Status = "degraded"
			result.ErrorMessage = reason
		case "unknown":
			// An unavailable renderer/reviewer is not a failed account and must
			// never count as a healthy or degraded verdict.
			result.Status = "inconclusive"
			result.ErrorMessage = reason
		}
	}
	if plan.QualityCheckEnabled && plan.QualityMode == ScheduledTestQualityModeCandy && result.Status == "failed" {
		result.Status = "inconclusive"
		if strings.TrimSpace(result.ErrorMessage) == "" {
			result.ErrorMessage = "quality check inconclusive: candy answer unavailable"
		}
	}
	result.QualityMode = scheduledTestQualityMode(plan)

	saved := false
	if s.scheduledSvc == nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d scheduled test service is unavailable", plan.ID)
	} else if err := s.scheduledSvc.SaveResult(ctx, plan.ID, plan.MaxResults, result); err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d SaveResult error: %v", plan.ID, err)
	} else {
		saved = true
	}

	if saved && plan.QualityCheckEnabled {
		s.updateQualityScheduling(ctx, plan, result)
	}

	// Plain connectivity plans keep the upstream auto-recovery behavior.
	if saved && !plan.QualityCheckEnabled && result.Status == "success" && plan.AutoRecover {
		s.tryRecoverAccount(ctx, plan.AccountID, plan.ID)
	}

	s.finishScheduledPlan(ctx, plan, nextRun)
}

func (s *ScheduledTestRunnerService) claimScheduledPlan(ctx context.Context, plan *ScheduledTestPlan) (time.Time, bool) {
	if s == nil || s.planRepo == nil || plan == nil {
		return time.Time{}, false
	}
	now := time.Now()
	nextRun, err := computeNextRun(plan.CronExpression, now)
	if err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d computeNextRun error: %v", plan.ID, err)
		return time.Time{}, false
	}

	updateCtx, cancelUpdate := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelUpdate()
	if err := s.planRepo.UpdateAfterRun(updateCtx, plan.ID, now, nextRun); err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d claim failed: %v", plan.ID, err)
		return time.Time{}, false
	}
	return nextRun, true
}

func (s *ScheduledTestRunnerService) finishScheduledPlan(ctx context.Context, plan *ScheduledTestPlan, nextRun time.Time) {
	if s == nil || s.planRepo == nil || plan == nil {
		return
	}
	now := time.Now()
	updateCtx, cancelUpdate := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelUpdate()
	if err := s.planRepo.UpdateAfterRun(updateCtx, plan.ID, now, nextRun); err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d finish update error: %v", plan.ID, err)
	}
}

func (s *ScheduledTestRunnerService) saveInconclusiveResult(ctx context.Context, plan *ScheduledTestPlan, reason string) {
	if s == nil || s.scheduledSvc == nil || plan == nil {
		return
	}
	now := time.Now()
	result := &ScheduledTestResult{
		Status:       "inconclusive",
		ErrorMessage: reason,
		QualityMode:  scheduledTestQualityMode(plan),
		StartedAt:    now,
		FinishedAt:   now,
	}
	if err := s.scheduledSvc.SaveResult(ctx, plan.ID, plan.MaxResults, result); err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d SaveResult inconclusive error: %v", plan.ID, err)
	}
}

func scheduledTestQualityMode(plan *ScheduledTestPlan) string {
	if plan == nil || plan.QualityMode == "" {
		return ScheduledTestQualityModePelican
	}
	return plan.QualityMode
}

func (s *ScheduledTestRunnerService) accountRepo() AccountRepository {
	if s == nil || s.accountTestSvc == nil {
		return nil
	}
	return s.accountTestSvc.accountRepo
}

// updateQualityScheduling applies the two-sample quality policy after the
// result has been durably stored. All repository failures are fail-open: a
// probe must not make an account unavailable merely because the protection
// bookkeeping is temporarily unavailable.
func (s *ScheduledTestRunnerService) updateQualityScheduling(ctx context.Context, plan *ScheduledTestPlan, result *ScheduledTestResult) {
	if s == nil || plan == nil || result == nil || s.scheduledSvc == nil {
		return
	}
	repo := s.accountRepo()
	if repo == nil {
		return
	}

	switch result.Status {
	case "degraded":
		results, err := s.scheduledSvc.ListResults(ctx, plan.ID, 2)
		if err != nil {
			logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d quality history unavailable: %v", plan.ID, err)
			return
		}
		if !hasConsecutiveDegradedResultsForMode(results, scheduledTestQualityMode(plan)) {
			return
		}
		s.pauseAccountForQuality(ctx, repo, plan, result)
	case "success":
		// Only an actual quality verdict may clear a previous quality pause.
		// Custom prompts are excluded by the caller.
		s.recoverAccountFromQuality(ctx, repo, plan.AccountID, plan.ID)
	}
}

func hasConsecutiveDegradedResultsForMode(results []*ScheduledTestResult, mode string) bool {
	if mode == "" {
		mode = ScheduledTestQualityModePelican
	}
	if len(results) < 2 || results[0] == nil || results[1] == nil {
		return false
	}
	for _, result := range results[:2] {
		resultMode := result.QualityMode
		if resultMode == "" {
			resultMode = ScheduledTestQualityModePelican
		}
		if resultMode != mode || result.Status != "degraded" {
			return false
		}
	}
	return true
}

func hasConsecutiveDegradedResults(results []*ScheduledTestResult) bool {
	return len(results) >= 2 && results[0] != nil && results[1] != nil &&
		results[0].Status == "degraded" && results[1].Status == "degraded"
}

func (s *ScheduledTestRunnerService) pauseAccountForQuality(ctx context.Context, repo AccountRepository, plan *ScheduledTestPlan, result *ScheduledTestResult) {
	if plan == nil || repo == nil {
		return
	}
	account, err := repo.GetByID(ctx, plan.AccountID)
	if err != nil || account == nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d quality pause account lookup failed: %v", plan.ID, err)
		return
	}
	if account.Type == AccountTypeUpstream {
		// An upstream account is a pass-through channel. Its quality probe may
		// still be recorded, but it must never be auto-paused.
		return
	}
	if !account.Schedulable {
		// It was already paused by an operator or another policy. Do not claim
		// ownership of that state and do not overwrite its pause reason.
		return
	}
	reason := scheduledQualityReason(plan.ID, result.ErrorMessage)
	markerRepo, ok := repo.(scheduledQualityPauseRepository)
	if !ok {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d quality pause repository is unavailable", plan.ID)
		return
	}
	changed, err := markerRepo.MarkScheduledQualityPause(ctx, plan.ID, account.ID, plan.PromptText, account.GroupIDs, reason)
	if err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d quality pause failed: %v", plan.ID, err)
		return
	}
	if changed {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d quality paused account=%d", plan.ID, account.ID)
	}
}

func (s *ScheduledTestRunnerService) recoverAccountFromQuality(ctx context.Context, repo AccountRepository, accountID, planID int64) {
	account, err := repo.GetByID(ctx, accountID)
	if err != nil || account == nil || !strings.HasPrefix(account.TempUnschedulableReason, fmt.Sprintf("%s plan=%d:", scheduledQualityReasonPrefix, planID)) {
		return
	}
	markerRepo, ok := repo.(scheduledQualityPauseRepository)
	if !ok {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] quality recovery account=%d repository is unavailable", accountID)
		return
	}
	changed, err := markerRepo.ClearScheduledQualityPause(ctx, accountID, planID)
	if err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] quality recovery account=%d failed: %v", accountID, err)
		return
	}
	if changed {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] quality recovery account=%d", accountID)
	}
}

func scheduledQualityReason(planID int64, detail string) string {
	detail = strings.TrimSpace(detail)
	if detail == "" {
		detail = "consecutive degraded scheduled-test results"
	}
	reason := fmt.Sprintf("%s plan=%d: %s", scheduledQualityReasonPrefix, planID, detail)
	if runes := []rune(reason); len(runes) > 512 {
		return string(runes[:512])
	}
	return reason
}

// tryRecoverAccount attempts to recover an account from recoverable runtime state.
func (s *ScheduledTestRunnerService) tryRecoverAccount(ctx context.Context, accountID int64, planID int64) {
	if s.rateLimitSvc == nil {
		return
	}

	recovery, err := s.rateLimitSvc.RecoverAccountAfterSuccessfulTest(ctx, accountID)
	if err != nil {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d auto-recover failed: %v", planID, err)
		return
	}
	if recovery == nil {
		return
	}

	if recovery.ClearedError {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d auto-recover: account=%d recovered from error status", planID, accountID)
	}
	if recovery.ClearedRateLimit {
		logger.LegacyPrintf("service.scheduled_test_runner", "[ScheduledTestRunner] plan=%d auto-recover: account=%d cleared rate-limit/runtime state", planID, accountID)
	}
}
