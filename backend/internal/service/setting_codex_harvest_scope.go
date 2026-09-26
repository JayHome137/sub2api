package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
)

const SettingKeyOpenAICodexTicketHarvestScope = "openai_codex_ticket_harvest_scope"

type cachedOpenAICodexTicketHarvestScope struct {
	scope     CodexTicketHarvestScope
	expiresAt int64
}

const (
	CodexHarvestSchedulableOnly       = "schedulable_only"
	CodexHarvestPrioritizeSchedulable = "prioritize_schedulable"
)

// CodexTicketHarvestScope controls background harvesting only. It does not
// change request routing or invalidate existing tickets.
type CodexTicketHarvestScope struct {
	Mode          string  `json:"mode"`
	GroupIDs      []int64 `json:"group_ids"`
	AccountPolicy string  `json:"account_policy"`
}

func NormalizeCodexTicketHarvestScope(scope CodexTicketHarvestScope) (CodexTicketHarvestScope, error) {
	if scope.Mode == "" {
		scope.Mode = "all"
	}
	if scope.Mode != "all" && scope.Mode != "selected" {
		return scope, fmt.Errorf("harvest scope mode must be all or selected")
	}
	if scope.AccountPolicy == "" {
		scope.AccountPolicy = CodexHarvestSchedulableOnly
	}
	if scope.AccountPolicy != CodexHarvestSchedulableOnly && scope.AccountPolicy != CodexHarvestPrioritizeSchedulable {
		return scope, fmt.Errorf("harvest account policy must be schedulable_only or prioritize_schedulable")
	}
	if len(scope.GroupIDs) > 1000 {
		return scope, fmt.Errorf("at most 1000 harvest groups are allowed")
	}
	ids := append([]int64{}, scope.GroupIDs...)
	for _, id := range ids {
		if id <= 0 {
			return scope, fmt.Errorf("harvest group IDs must be positive")
		}
	}
	slices.Sort(ids)
	scope.GroupIDs = slices.Compact(ids)
	return scope, nil
}

func parseCodexTicketHarvestScope(raw string) (CodexTicketHarvestScope, error) {
	if strings.TrimSpace(raw) == "" {
		return NormalizeCodexTicketHarvestScope(CodexTicketHarvestScope{})
	}
	var scope CodexTicketHarvestScope
	if err := json.Unmarshal([]byte(raw), &scope); err != nil {
		return scope, fmt.Errorf("invalid harvest scope JSON")
	}
	if scope.Mode == "" {
		return scope, fmt.Errorf("harvest scope mode is required")
	}
	return NormalizeCodexTicketHarvestScope(scope)
}

func (s *SettingService) GetCodexTicketHarvestScope(ctx context.Context) (CodexTicketHarvestScope, error) {
	if s == nil || s.settingRepo == nil {
		return parseCodexTicketHarvestScope("")
	}
	raw, err := s.settingRepo.GetValue(ctx, SettingKeyOpenAICodexTicketHarvestScope)
	if errors.Is(err, ErrSettingNotFound) {
		return parseCodexTicketHarvestScope("")
	}
	if err != nil {
		return CodexTicketHarvestScope{}, err
	}
	return parseCodexTicketHarvestScope(raw)
}

func (s *SettingService) InvalidateOpenAICodexTicketHarvestScopeCache() {
	if s == nil {
		return
	}
	s.openAICodexTicketHarvestScopeCache.Store(&cachedOpenAICodexTicketHarvestScope{expiresAt: 0})
	s.openAICodexTicketHarvestScopeSF.Forget(SettingKeyOpenAICodexTicketHarvestScope)
}

func (scope CodexTicketHarvestScope) includes(account *Account) bool {
	if account == nil {
		return false
	}
	if scope.Mode == "all" {
		return true
	}
	for _, group := range account.Groups {
		if group != nil && group.IsActive() && slices.Contains(scope.GroupIDs, group.ID) {
			return true
		}
	}
	for _, id := range account.GroupIDs {
		if slices.Contains(scope.GroupIDs, id) {
			return true
		}
	}
	return false
}

func (scope CodexTicketHarvestScope) allowsAccount(account *Account) bool {
	if account == nil {
		return false
	}
	candidate := *account
	candidate.Schedulable = true
	if !candidate.IsSchedulable() {
		return false
	}
	return scope.AccountPolicy == CodexHarvestPrioritizeSchedulable || account.Schedulable
}

func (scope CodexTicketHarvestScope) priority(account *Account) int {
	best, found := account.Priority, false
	for _, membership := range account.AccountGroups {
		if scope.Mode == "selected" && !slices.Contains(scope.GroupIDs, membership.GroupID) {
			continue
		}
		if membership.Group != nil && !membership.Group.IsActive() {
			continue
		}
		if !found || membership.Priority < best {
			best, found = membership.Priority, true
		}
	}
	return best
}

type codexHarvestTier struct {
	Schedulable     bool
	Priority        int
	AccountPriority int
}

func (scope CodexTicketHarvestScope) tier(account *Account) codexHarvestTier {
	return codexHarvestTier{Schedulable: account.Schedulable, Priority: scope.priority(account), AccountPriority: account.Priority}
}
