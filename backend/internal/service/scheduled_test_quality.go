package service

import (
	"context"
	"io"
	"regexp"
	"strings"

	"golang.org/x/net/html"
)

// assessScheduledQuality selects the evaluator from the persisted plan mode.
// The mode is part of the plan contract so changing a prompt cannot silently
// switch an SVG review into answer matching (or the reverse).
func (s *AccountTestService) assessScheduledQuality(ctx context.Context, plan *ScheduledTestPlan, response string) (string, string) {
	if plan == nil {
		return "unknown", "quality check inconclusive: scheduled test plan is missing"
	}
	if plan.QualityMode == "" || plan.QualityMode == ScheduledTestQualityModePelican {
		return s.assessScheduledVisualQuality(ctx, plan, response)
	}
	if plan.QualityMode == ScheduledTestQualityModeCandy {
		return assessScheduledCandyQuality(response, plan.QualityExpectedAnswer)
	}
	return "unknown", "quality check inconclusive: unsupported quality mode"
}

func assessScheduledCandyQuality(response, expected string) (string, string) {
	expected = extractScheduledCandyAnswer(expected)
	if expected == "" {
		return "unknown", "quality check inconclusive: candy expected answer is empty"
	}
	answer := extractScheduledCandyAnswer(response)
	if answer == "" {
		return "unknown", "quality check inconclusive: candy answer is missing or ambiguous"
	}
	if answer != expected {
		return "degraded", "quality check failed: candy answer does not match the expected answer"
	}
	return "success", ""
}

func normalizeScheduledCandyAnswer(value string) string {
	value = strings.TrimSpace(strings.TrimPrefix(value, "\ufeff"))
	value = strings.NewReplacer("**", "", "__", "", "`", "", "\\(", "", "\\)", "").Replace(value)
	value = strings.Trim(value, "\"'")
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

var scheduledCandyAnswerCue = regexp.MustCompile(`(?i)(?:答案|answer|result|选择|取出|最少(?:取出)?|因此|所以)[^0-9]{0,24}([0-9]+)`)
var scheduledCandyNumber = regexp.MustCompile(`\d+`)

// extractScheduledCandyAnswer accepts a bare number or a clear answer phrase,
// while rejecting prompt echoes and explanations containing several numbers.
func extractScheduledCandyAnswer(value string) string {
	value = normalizeScheduledCandyAnswer(value)
	if value == "" {
		return ""
	}
	if matches := scheduledCandyAnswerCue.FindAllStringSubmatch(value, -1); len(matches) > 0 {
		// The final explicit answer/selection in a response is the model's
		// resolved choice; earlier numbers are often counterfactual cases.
		return matches[len(matches)-1][1]
	}
	numbers := scheduledCandyNumber.FindAllString(value, -1)
	if len(numbers) == 1 {
		return numbers[0]
	}
	return ""
}

// scheduledQualityReasonPrefix marks the only temporary pause that the
// scheduled-test runner is allowed to clear automatically. Keep this prefix
// stable because group quality settings use it to clean up old pauses.
const scheduledQualityReasonPrefix = "scheduled quality check:"

// Transport success and quality approval are separate outcomes. An arbitrary
// custom prompt has no local quality rubric and must not change account state.
func assessScheduledTestQuality(response, prompt string) (string, string) {
	if !isDefaultScheduledTestPrompt(prompt) {
		return "unknown", "quality check inconclusive: custom prompt has no quality evaluator"
	}
	if len(response) > 1024*1024 {
		return "unknown", "quality check inconclusive: document exceeds local analysis limit"
	}
	if reason := scheduledTestQualityFailure(response); reason != "" {
		return "degraded", reason
	}
	return scheduledTestAnimationQuality(response)
}

func scheduledTestQualityFailure(response string) string {
	content := strings.TrimSpace(strings.TrimPrefix(response, "\ufeff"))
	if content == "" {
		return "quality check failed: empty response"
	}
	if strings.Contains(content, "```") {
		return "quality check failed: response contains a code fence"
	}
	if !strings.HasPrefix(content, "<") || !strings.HasSuffix(content, ">") {
		return "quality check failed: response contains text outside the HTML document"
	}
	lower := strings.ToLower(content)
	if !strings.Contains(lower, "<html") || !strings.Contains(lower, "<svg") || !strings.Contains(lower, "</html>") {
		return "quality check failed: response is not a complete HTML/SVG document"
	}
	if !strings.Contains(lower, "</svg>") {
		return "quality check failed: SVG document is incomplete"
	}
	if reason := scheduledTestDocumentFailure(content); reason != "" {
		return reason
	}
	if !strings.Contains(lower, "<animate") &&
		!strings.Contains(lower, "@keyframes") &&
		!strings.Contains(lower, "animation:") &&
		!strings.Contains(lower, "animation-name") &&
		!strings.Contains(lower, "requestanimationframe") {
		return "quality check failed: no animation implementation detected"
	}
	if strings.Contains(lower, "<script src=") ||
		strings.Contains(lower, "<link ") ||
		strings.Contains(lower, "src=\"http") ||
		strings.Contains(lower, "href=\"http") ||
		strings.Contains(lower, "url(http") {
		return "quality check failed: external resource dependency detected"
	}
	return ""
}

func scheduledTestDocumentFailure(content string) string {
	// The tokenizer ignores fake closing tags inside comments and scripts.
	z := html.NewTokenizer(strings.NewReader(content))
	htmlDepth, svgDepth, htmlCount, svgCount := 0, 0, 0, 0
	for {
		tt := z.Next()
		if tt == html.ErrorToken {
			if z.Err() != io.EOF {
				return "quality check failed: invalid HTML document"
			}
			break
		}
		if tt != html.StartTagToken && tt != html.EndTagToken && tt != html.SelfClosingTagToken {
			continue
		}
		token := z.Token()
		switch token.Data {
		case "html":
			switch tt {
			case html.StartTagToken:
				htmlDepth++
				htmlCount++
			case html.EndTagToken:
				htmlDepth--
			}
		case "svg":
			switch tt {
			case html.StartTagToken:
				svgDepth++
				svgCount++
			case html.EndTagToken:
				svgDepth--
			}
		}
		if htmlDepth < 0 || svgDepth < 0 {
			return "quality check failed: unbalanced HTML/SVG document"
		}
		if tt == html.EndTagToken {
			continue
		}
		for _, attr := range token.Attr {
			value := strings.ToLower(strings.TrimSpace(attr.Val))
			if (token.Data == "script" && attr.Key == "src") ||
				(token.Data == "link" && attr.Key == "href") ||
				((attr.Key == "href" || attr.Key == "src") && (strings.HasPrefix(value, "http:") || strings.HasPrefix(value, "https:") || strings.HasPrefix(value, "//"))) {
				return "quality check failed: external resource dependency detected"
			}
		}
	}
	if htmlDepth != 0 || svgDepth != 0 || svgCount == 0 || htmlCount != 1 {
		return "quality check failed: unbalanced HTML/SVG document"
	}
	return ""
}
