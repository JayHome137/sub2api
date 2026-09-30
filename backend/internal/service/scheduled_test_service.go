package service

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
)

const (
	DefaultScheduledTestPrompt = "请生成可直接运行的单文件HTML，使用内联SVG绘制鹈鹕骑自行车的二维循环动画。画面以鹈鹕和自行车为主体，展示清晰的身体结构、踩踏动作和车轮转动，配合协调的背景、配色与层次。动画应流畅自然、衔接连续，并适配不同屏幕尺寸。动画必须用 CSS @keyframes 或 SMIL（animate/animateTransform）实现，不要使用 JavaScript 或 <script> 标签。禁止依赖外部资源，只输出完整HTML，不要代码围栏或解释文字。"
	DefaultScheduledTestCron   = "*/5 * * * *"
	maxScheduledTestPromptSize = 32 * 1024
)

// legacyScheduledTestPrompts keeps older default questions equivalent to the
// current evaluator input. Plans store a prompt snapshot, so changing the
// default must not silently turn existing plans into custom prompts.
var legacyScheduledTestPrompts = []string{
	"请生成可直接运行的单文件HTML，使用内联SVG绘制鹈鹕骑自行车的二维循环动画。画面以鹈鹕和自行车为主体，展示清晰的身体结构、踩踏动作和车轮转动，配合协调的背景、配色与层次。动画应流畅自然、衔接连续，并适配不同屏幕尺寸。禁止依赖外部资源，只输出完整HTML，不要代码围栏或解释文字。",
}

// ScheduledTestQualityPrompts returns the prompt snapshots that use the
// built-in animation quality rubric. Custom prompts deliberately stay out of
// group quality aggregation and must never be treated as a passing verdict.
func ScheduledTestQualityPrompts() []string {
	prompts := make([]string, 0, len(legacyScheduledTestPrompts)+1)
	prompts = append(prompts, DefaultScheduledTestPrompt)
	prompts = append(prompts, legacyScheduledTestPrompts...)
	return prompts
}

func isDefaultScheduledTestPrompt(prompt string) bool {
	trimmed := strings.TrimSpace(prompt)
	if trimmed == "" || trimmed == DefaultScheduledTestPrompt {
		return true
	}
	for _, legacy := range legacyScheduledTestPrompts {
		if trimmed == legacy {
			return true
		}
	}
	return false
}

var scheduledTestCronParser = cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow)

// ScheduledTestService provides CRUD operations for scheduled test plans and results.
type ScheduledTestService struct {
	planRepo    ScheduledTestPlanRepository
	resultRepo  ScheduledTestResultRepository
	accountRepo AccountRepository
}

// NewScheduledTestService creates a new ScheduledTestService.
func NewScheduledTestService(
	planRepo ScheduledTestPlanRepository,
	resultRepo ScheduledTestResultRepository,
	accountRepos ...AccountRepository,
) *ScheduledTestService {
	svc := &ScheduledTestService{
		planRepo:   planRepo,
		resultRepo: resultRepo,
	}
	if len(accountRepos) > 0 {
		svc.accountRepo = accountRepos[0]
	}
	return svc
}

// CreatePlan validates the cron expression, computes next_run_at, and persists the plan.
func (s *ScheduledTestService) CreatePlan(ctx context.Context, plan *ScheduledTestPlan) (*ScheduledTestPlan, error) {
	if err := normalizeScheduledTestPlan(plan); err != nil {
		return nil, err
	}
	nextRun, err := computeNextRun(plan.CronExpression, time.Now())
	if err != nil {
		return nil, fmt.Errorf("invalid cron expression: %w", err)
	}
	plan.NextRunAt = &nextRun

	if plan.MaxResults <= 0 {
		plan.MaxResults = 50
	}

	return s.planRepo.Create(ctx, plan)
}

// GetPlan retrieves a plan by ID.
func (s *ScheduledTestService) GetPlan(ctx context.Context, id int64) (*ScheduledTestPlan, error) {
	return s.planRepo.GetByID(ctx, id)
}

// ListPlansByAccount returns all plans for a given account.
func (s *ScheduledTestService) ListPlansByAccount(ctx context.Context, accountID int64) ([]*ScheduledTestPlan, error) {
	return s.planRepo.ListByAccountID(ctx, accountID)
}

// UpdatePlan validates cron and updates the plan.
func (s *ScheduledTestService) UpdatePlan(ctx context.Context, plan *ScheduledTestPlan) (*ScheduledTestPlan, error) {
	if plan == nil {
		return nil, fmt.Errorf("scheduled test plan is required")
	}
	existing, err := s.planRepo.GetByID(ctx, plan.ID)
	if err != nil {
		return nil, err
	}
	if err := normalizeScheduledTestPlan(plan); err != nil {
		return nil, err
	}
	nextRun, err := computeNextRun(plan.CronExpression, time.Now())
	if err != nil {
		return nil, fmt.Errorf("invalid cron expression: %w", err)
	}
	plan.NextRunAt = &nextRun

	updated, err := s.planRepo.Update(ctx, plan)
	if err != nil {
		return nil, err
	}
	if updated == nil {
		return nil, nil
	}
	promptChanged := existing != nil && existing.PromptText != updated.PromptText
	if !updated.Enabled || !updated.QualityCheckEnabled || promptChanged || !isDefaultScheduledTestPrompt(updated.PromptText) {
		if err := s.clearQualityPause(ctx, updated.ID); err != nil {
			return nil, fmt.Errorf("clear scheduled quality pause: %w", err)
		}
	}
	return updated, nil
}

func normalizeScheduledTestPlan(plan *ScheduledTestPlan) error {
	if plan == nil {
		return fmt.Errorf("scheduled test plan is required")
	}
	plan.PromptText = strings.TrimSpace(plan.PromptText)
	if plan.PromptText == "" {
		plan.PromptText = DefaultScheduledTestPrompt
	}
	if len([]byte(plan.PromptText)) > maxScheduledTestPromptSize {
		return fmt.Errorf("scheduled test prompt is too long")
	}
	plan.CronExpression = strings.TrimSpace(plan.CronExpression)
	if plan.CronExpression == "" {
		plan.CronExpression = DefaultScheduledTestCron
	}
	return nil
}

// DeletePlan removes a plan and its results (via CASCADE).
func (s *ScheduledTestService) DeletePlan(ctx context.Context, id int64) error {
	if err := s.planRepo.Delete(ctx, id); err != nil {
		return err
	}
	if err := s.clearQualityPause(ctx, id); err != nil {
		return fmt.Errorf("clear scheduled quality pause: %w", err)
	}
	return nil
}

type scheduledQualityPausePlanRepository interface {
	ClearScheduledQualityPauseByPlan(ctx context.Context, planID int64) error
}

func (s *ScheduledTestService) clearQualityPause(ctx context.Context, planID int64) error {
	if s.accountRepo == nil {
		return nil
	}
	repo, ok := s.accountRepo.(scheduledQualityPausePlanRepository)
	if !ok {
		return nil
	}
	return repo.ClearScheduledQualityPauseByPlan(ctx, planID)
}

// ListResults returns the most recent results for a plan.
func (s *ScheduledTestService) ListResults(ctx context.Context, planID int64, limit int) ([]*ScheduledTestResult, error) {
	if limit <= 0 {
		limit = 50
	}
	return s.resultRepo.ListByPlanID(ctx, planID, limit)
}

// SaveResult inserts a result and prunes old entries beyond maxResults.
func (s *ScheduledTestService) SaveResult(ctx context.Context, planID int64, maxResults int, result *ScheduledTestResult) error {
	if result == nil {
		return fmt.Errorf("scheduled test result is required")
	}
	result.ID = 0
	result.PlanID = planID
	saved, err := s.resultRepo.Create(ctx, result)
	if err != nil {
		return err
	}
	if saved == nil || saved.ID <= 0 || saved.PlanID != planID {
		return fmt.Errorf("scheduled test result was not persisted")
	}
	*result = *saved
	keepCount := maxResults
	if keepCount < 2 {
		keepCount = 2
	}
	return s.resultRepo.PruneOldResults(ctx, planID, keepCount)
}

func computeNextRun(cronExpr string, from time.Time) (time.Time, error) {
	sched, err := scheduledTestCronParser.Parse(cronExpr)
	if err != nil {
		return time.Time{}, err
	}
	return sched.Next(from), nil
}
