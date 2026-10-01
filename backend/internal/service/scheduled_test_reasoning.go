package service

import (
	"context"
	"strings"
)

type scheduledTestReasoningEffortContextKey struct{}

func withScheduledTestReasoningEffort(ctx context.Context, effort string) context.Context {
	return context.WithValue(ctx, scheduledTestReasoningEffortContextKey{}, strings.TrimSpace(effort))
}

func scheduledTestReasoningEffort(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	effort, _ := ctx.Value(scheduledTestReasoningEffortContextKey{}).(string)
	return strings.TrimSpace(effort)
}

// applyScheduledTestReasoningEffort maps the plan-level option to the native
// request field for protocols that support an explicit effort value. Empty
// effort leaves the provider's default untouched; unsupported protocols are
// intentionally unchanged.
func applyScheduledTestReasoningEffort(ctx context.Context, payload map[string]any, protocol, model string) {
	effort := scheduledTestReasoningEffort(ctx)
	if effort == "" || payload == nil {
		return
	}
	switch protocol {
	case "responses":
		if normalized := normalizeOpenAIReasoningEffortForModel(effort, model); normalized != "" {
			payload["reasoning"] = map[string]any{"effort": normalized}
		}
	case "chat_completions":
		if normalized := normalizeOpenAIReasoningEffortForModel(effort, model); normalized != "" {
			payload["reasoning_effort"] = normalized
		}
	case "anthropic":
		if normalized := NormalizeClaudeOutputEffort(effort); normalized != nil {
			payload["output_config"] = map[string]any{"effort": *normalized}
		}
	}
}
