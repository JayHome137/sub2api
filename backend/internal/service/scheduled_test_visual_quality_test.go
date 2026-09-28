package service

import (
	"strings"
	"testing"
)

func TestScheduledVisualMotionIgnoresPedalingCoordination(t *testing.T) {
	if !strings.Contains(scheduledVisualReviewPrompt, "Pedaling/foot/wheel coordination is not judged here") {
		t.Fatal("visual review prompt must not fail animation for pedal/foot/wheel coordination")
	}
	status, reason := parseScheduledVisualReview(`{"checks":{"pelican":true,"bicycle":true,"riding":true,"motion":false}}`)
	if status != "degraded" || !strings.Contains(reason, "animation is static or clearly broken") {
		t.Fatalf("motion failure = (%q, %q), want static/broken animation verdict", status, reason)
	}
}

func TestScheduledVisualReviewUsesOverallImpression(t *testing.T) {
	for _, criterion := range []string{
		"Judge the overall impression",
		"Minor anatomy inaccuracies, rough or stiff drawing, approximate or simplified pedaling",
		"Exact foot-to-pedal contact is not required",
		"Fail only when the bird is clearly not on the bicycle",
	} {
		if !strings.Contains(scheduledVisualReviewPrompt, criterion) {
			t.Errorf("visual review prompt is missing its lenient criterion %q", criterion)
		}
	}
	for _, strictCriterion := range []string{
		"Trace the actual foot endpoint",
		"A single definite defect makes that criterion false",
	} {
		if strings.Contains(scheduledVisualReviewPrompt, strictCriterion) {
			t.Errorf("visual review prompt still applies detail-level criterion %q", strictCriterion)
		}
	}
}

func TestReviewRequestErrorIsCapabilityRecognizesResponsesAndChatCompletions(t *testing.T) {
	tests := []struct {
		name    string
		message string
		want    bool
	}{
		{name: "responses", message: "API returned 400: unsupported image input", want: true},
		{name: "chat completions", message: "Chat Completions API (/v1/chat/completions) returned 400: unsupported image input", want: true},
		{name: "timeout", message: "API returned 408: timeout", want: false},
		{name: "rate limit", message: "Chat Completions API (/v1/chat/completions) returned 429: rate limited", want: false},
		{name: "transport", message: "Request failed: connection reset", want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := reviewRequestErrorIsCapability(test.message); got != test.want {
				t.Fatalf("reviewRequestErrorIsCapability(%q) = %v, want %v", test.message, got, test.want)
			}
		})
	}
}
