package service

import "testing"

func TestAssessScheduledCandyQuality(t *testing.T) {
	tests := []struct {
		name     string
		response string
		expected string
		status   string
	}{
		{name: "matching answer", response: "5", expected: "5", status: "success"},
		{name: "matching answer with whitespace", response: " 5\n", expected: "5", status: "success"},
		{name: "wrong answer", response: "4", expected: "5", status: "degraded"},
		{name: "empty answer", response: "", expected: "5", status: "unknown"},
		{name: "empty expected answer", response: "5", expected: "", status: "unknown"},
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
