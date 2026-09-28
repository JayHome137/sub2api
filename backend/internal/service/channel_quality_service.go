package service

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"
)

var ErrChannelQualityConfigConflict = fmt.Errorf("channel quality configuration conflict")

// ChannelQualityService owns the independent quality task and its history.
// It uses the account probe path in read-only mode and never exposes the
// selected account in its results.
type ChannelQualityService struct {
	repo        ChannelQualityRepository
	accountRepo AccountRepository
	groupRepo   GroupRepository
	channels    *ChannelService
	accountTest *AccountTestService
	runMu       sync.Mutex
}

func NewChannelQualityService(repo ChannelQualityRepository, accountRepo AccountRepository, groupRepo GroupRepository, channels *ChannelService, accountTest *AccountTestService) *ChannelQualityService {
	return &ChannelQualityService{repo: repo, accountRepo: accountRepo, groupRepo: groupRepo, channels: channels, accountTest: accountTest}
}

func (s *ChannelQualityService) GetConfig(ctx context.Context) (*ChannelQualityConfig, error) {
	cfg, err := s.repo.GetConfig(ctx)
	if err != nil {
		return nil, err
	}
	return normalizeChannelQualityConfig(cfg), nil
}

func (s *ChannelQualityService) UpdateConfig(ctx context.Context, cfg ChannelQualityConfig) (*ChannelQualityConfig, error) {
	cfg = *normalizeChannelQualityConfig(&cfg)
	if len([]rune(cfg.Prompt)) > 2000 || len([]rune(cfg.ExpectedAnswer)) > 200 {
		return nil, fmt.Errorf("quality prompt or expected answer is too long")
	}
	updated, err := s.repo.UpdateConfig(ctx, &cfg)
	if err != nil {
		return nil, err
	}
	return normalizeChannelQualityConfig(updated), nil
}

func normalizeChannelQualityConfig(cfg *ChannelQualityConfig) *ChannelQualityConfig {
	if cfg == nil {
		cfg = &ChannelQualityConfig{}
	}
	copy := *cfg
	if copy.IntervalSeconds < 60 {
		copy.IntervalSeconds = int(ChannelQualityDefaultInterval.Seconds())
	}
	if copy.IntervalSeconds > 86400 {
		copy.IntervalSeconds = 86400
	}
	copy.Model = strings.TrimSpace(copy.Model)
	copy.Prompt = strings.TrimSpace(copy.Prompt)
	if copy.Prompt == "" {
		copy.Prompt = ChannelQualityDefaultPrompt
	}
	copy.ExpectedAnswer = strings.TrimSpace(copy.ExpectedAnswer)
	if copy.ExpectedAnswer == "" {
		copy.ExpectedAnswer = ChannelQualityDefaultExpected
	}
	if copy.HistoryLimit < 10 {
		copy.HistoryLimit = 100
	}
	if copy.HistoryLimit > 1000 {
		copy.HistoryLimit = 1000
	}
	return &copy
}

func (s *ChannelQualityService) List(ctx context.Context, groupIDs []int64) ([]*ChannelQualityView, error) {
	cfg, err := s.GetConfig(ctx)
	if err != nil {
		return nil, err
	}
	return s.repo.ListLatest(ctx, groupIDs, cfg.HistoryLimit)
}

func (s *ChannelQualityService) History(ctx context.Context, groupID int64, limit int) ([]*ChannelQualityResult, error) {
	return s.repo.ListHistory(ctx, groupID, limit)
}

func (s *ChannelQualityService) RunNow(ctx context.Context) error {
	if !s.runMu.TryLock() {
		return ErrChannelQualityConfigConflict
	}
	defer s.runMu.Unlock()

	cfg, err := s.GetConfig(ctx)
	if err != nil {
		return err
	}
	return s.runGroups(ctx, cfg)
}

func (s *ChannelQualityService) runGroups(ctx context.Context, cfg *ChannelQualityConfig) error {
	groups, err := s.groupRepo.ListActive(ctx)
	if err != nil {
		return fmt.Errorf("list quality groups: %w", err)
	}
	for i := range groups {
		_ = s.runGroup(ctx, &groups[i], cfg)
	}
	now := time.Now().UTC()
	cfg.LastRunAt = &now
	_, err = s.repo.UpdateConfig(ctx, cfg)
	return err
}

func (s *ChannelQualityService) runGroup(ctx context.Context, group *Group, cfg *ChannelQualityConfig) error {
	if group == nil || s.channels == nil {
		return nil
	}
	channel, err := s.channels.GetChannelForGroup(ctx, group.ID)
	if err != nil || channel == nil {
		return err
	}
	model := qualityModelForGroup(cfg.Model, group.Platform)
	started := time.Now().UTC()
	row, err := s.repo.CreateResult(ctx, &ChannelQualityResult{
		GroupID: group.ID, ChannelID: &channel.ID, GroupName: group.Name,
		ChannelName: channel.Name, Platform: group.Platform, Model: model,
		Status: ChannelQualityRunning, CheckedAt: started,
	})
	if err != nil {
		return err
	}
	finish := func(status, message string, latency int64) error {
		row.Status, row.Message, row.LatencyMs, row.CheckedAt = status, message, &latency, time.Now().UTC()
		return s.repo.UpdateResult(ctx, row)
	}

	accounts, err := s.accountRepo.ListByGroup(ctx, group.ID)
	if err != nil {
		return finish(ChannelQualityUnknown, "无法读取可用上游账号", time.Since(started).Milliseconds())
	}
	accountID := int64(0)
	for i := range accounts {
		if accounts[i].IsSchedulable() {
			accountID = accounts[i].ID
			break
		}
	}
	if accountID == 0 {
		for i := range accounts {
			if accounts[i].IsActive() {
				accountID = accounts[i].ID
				break
			}
		}
	}
	if accountID == 0 || s.accountTest == nil {
		return finish(ChannelQualityUnknown, "当前分组没有可检测的上游账号", time.Since(started).Milliseconds())
	}
	test, testErr := s.accountTest.RunReadOnlyTestBackgroundWithPrompt(ctx, accountID, model, cfg.Prompt)
	latency := time.Since(started).Milliseconds()
	if testErr != nil || test == nil || test.Status != "success" {
		return finish(ChannelQualityUnknown, "上游请求未完成，暂时无法判断质量", latency)
	}
	if qualityAnswerMatches(test.ResponseText, cfg.ExpectedAnswer) {
		return finish(ChannelQualityHealthy, "探测响应符合预期", latency)
	}
	return finish(ChannelQualityDegraded, "探测响应未达到预期，建议切换渠道", latency)
}

func qualityAnswerMatches(response, expected string) bool {
	response = strings.ToLower(strings.Join(strings.Fields(response), " "))
	expected = strings.ToLower(strings.Join(strings.Fields(expected), " "))
	return expected != "" && strings.Contains(response, expected)
}

func qualityModelForGroup(configured, platform string) string {
	if strings.TrimSpace(configured) != "" {
		return strings.TrimSpace(configured)
	}
	switch platform {
	case PlatformAnthropic:
		return "claude-sonnet-4-6"
	case PlatformGemini:
		return "gemini-2.5-flash"
	case PlatformGrok:
		return "grok-4-1-fast-reasoning"
	default:
		return "gpt-5.5"
	}
}

// ChannelQualityRunner runs a bounded scan every minute and only performs
// work when the independent quality setting is enabled and due.
type ChannelQualityRunner struct {
	svc      *ChannelQualityService
	stop     chan struct{}
	stopOnce sync.Once
	wg       sync.WaitGroup
}

func NewChannelQualityRunner(svc *ChannelQualityService) *ChannelQualityRunner {
	return &ChannelQualityRunner{svc: svc, stop: make(chan struct{})}
}

func (r *ChannelQualityRunner) Start() {
	if r == nil || r.svc == nil {
		return
	}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				r.tick()
			case <-r.stop:
				return
			}
		}
	}()
}

func (r *ChannelQualityRunner) tick() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cfg, err := r.svc.GetConfig(ctx)
	if err != nil || !cfg.Enabled {
		return
	}
	if cfg.LastRunAt != nil && time.Since(*cfg.LastRunAt) < time.Duration(cfg.IntervalSeconds)*time.Second {
		return
	}
	_ = r.svc.RunNow(ctx)
}

func (r *ChannelQualityRunner) Stop() {
	if r == nil {
		return
	}
	r.stopOnce.Do(func() { close(r.stop) })
	r.wg.Wait()
}
