package service

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"net/http"
	"net/http/httptest"
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
		"different but comparable drawing that satisfies the criteria is accepted",
		"Simplified frames, missing handlebars or pedals, stylized geometry",
		"Exact foot-to-pedal contact is NOT required",
		"Fail only when the bird is clearly not on the bicycle",
		"Pedaling/foot/wheel coordination is not judged here",
	} {
		if !strings.Contains(scheduledVisualReviewPrompt, criterion) {
			t.Errorf("visual review prompt is missing its lenient criterion %q", criterion)
		}
	}
	for _, strictCriterion := range []string{
		"Trace the actual foot endpoint",
		"At least one visible foot must touch a pedal surface",
	} {
		if strings.Contains(scheduledVisualReviewPrompt, strictCriterion) {
			t.Errorf("visual review prompt still applies detail-level criterion %q", strictCriterion)
		}
	}
}

func TestScheduledVisualReferenceIsEmbedded(t *testing.T) {
	if !strings.Contains(scheduledVisualReferenceHTML, "<svg") {
		t.Fatal("visual reference must contain an SVG scene")
	}
	if !strings.Contains(scheduledVisualReferenceHTML, "@keyframes") {
		t.Fatal("visual reference must contain deterministic animation")
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

func TestRenderScheduledVisualFramesHTTPValidatesSidecarResponse(t *testing.T) {
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, image.NewRGBA(image.Rect(0, 0, 960, 640))); err != nil {
		t.Fatal(err)
	}
	frames := make([]scheduledVisualFrame, 4)
	for i := range frames {
		frames[i] = scheduledVisualFrame{Time: float64(i), PNG: base64.StdEncoding.EncodeToString(encoded.Bytes())}
	}
	payload, err := json.Marshal(frames)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/render" {
			t.Errorf("request = %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(payload)
	}))
	defer server.Close()
	t.Setenv("SUB2API_QUALITY_RENDERER_URL", server.URL+"/render")
	got, err := renderScheduledVisualFramesHTTP(t.Context(), "<svg></svg>")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 4 || got[3].Time != 3 {
		t.Fatalf("frames = %#v", got)
	}
}

func TestRenderScheduledVisualFramesHTTPRejectsUnsafeURL(t *testing.T) {
	for _, value := range []string{"", "file:///tmp/render", "http://user:pass@example.test/render", "//example.test/render"} {
		t.Run(value, func(t *testing.T) {
			t.Setenv("SUB2API_QUALITY_RENDERER_URL", value)
			if _, err := renderScheduledVisualFramesHTTP(t.Context(), "<svg></svg>"); err == nil {
				t.Fatal("expected renderer URL validation error")
			}
		})
	}
}
