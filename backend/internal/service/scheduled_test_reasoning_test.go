package service

import (
	"context"
	"testing"
)

func TestApplyScheduledTestReasoningEffort(t *testing.T) {
	ctx := withScheduledTestReasoningEffort(context.Background(), "high")
	responses := map[string]any{}
	applyScheduledTestReasoningEffort(ctx, responses, "responses", "gpt-5.4")
	if got := responses["reasoning"].(map[string]any)["effort"]; got != "high" {
		t.Fatalf("responses effort=%v, want high", got)
	}

	chat := map[string]any{}
	applyScheduledTestReasoningEffort(ctx, chat, "chat_completions", "deepseek-v4")
	if got := chat["reasoning_effort"]; got != "high" {
		t.Fatalf("chat effort=%v, want high", got)
	}

	anthropic := map[string]any{}
	applyScheduledTestReasoningEffort(ctx, anthropic, "anthropic", "claude-sonnet-4-6")
	if got := anthropic["output_config"].(map[string]any)["effort"]; got != "high" {
		t.Fatalf("anthropic effort=%v, want high", got)
	}
}

func TestApplyScheduledTestReasoningEffortLeavesUnsetPayloadUntouched(t *testing.T) {
	payload := map[string]any{}
	applyScheduledTestReasoningEffort(context.Background(), payload, "responses", "gpt-5.4")
	if len(payload) != 0 {
		t.Fatalf("payload changed without an explicit effort: %#v", payload)
	}
}
