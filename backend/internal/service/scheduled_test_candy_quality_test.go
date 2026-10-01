package service

import "testing"

func TestAssessScheduledCandyQuality(t *testing.T) {
	tests := []struct {
		name     string
		response string
		expected string
		status   string
	}{
		{name: "matching answer", response: "21", expected: "21", status: "success"},
		{name: "matching answer phrase", response: "答案是 21 个", expected: "21", status: "success"},
		{name: "final selection wins", response: "如果不允许选择，答案是 **29 个**。\n### 可以按形状选择：21 个", expected: "21", status: "success"},
		{name: "wrong answer", response: "20", expected: "21", status: "degraded"},
		{name: "ambiguous explanation", response: "苹果 7，桃子 9，答案是 21", expected: "21", status: "success"},
		{name: "empty answer", response: "", expected: "21", status: "unknown"},
		{name: "empty expected answer", response: "21", expected: "", status: "unknown"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			status, _ := assessScheduledCandyQuality(tc.response, tc.expected)
			if status != tc.status {
				t.Fatalf("status=%q, want %q", status, tc.status)
			}
		})
	}
}

func TestHasConsecutiveDegradedResultsForModeIgnoresPreviousMode(t *testing.T) {
	results := []*ScheduledTestResult{
		{Status: "degraded", QualityMode: ScheduledTestQualityModeCandy},
		{Status: "degraded", QualityMode: ScheduledTestQualityModeCandy},
	}
	if !hasConsecutiveDegradedResultsForMode(results, ScheduledTestQualityModeCandy) {
		t.Fatal("two degraded candy results should count")
	}
	results[1].QualityMode = ScheduledTestQualityModePelican
	if hasConsecutiveDegradedResultsForMode(results, ScheduledTestQualityModeCandy) {
		t.Fatal("switching mode should reset the consecutive failure guard")
	}
}
