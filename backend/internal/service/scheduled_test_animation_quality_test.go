package service

import (
	"strings"
	"testing"
)

func TestScheduledAnimationQualityDoesNotFailRigidPedalingMotion(t *testing.T) {
	const document = `<html><svg>
	<style>
	@keyframes pedal { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
	.leg { animation: pedal 2s infinite; transform-box: fill-box; }
	</style>
	<path class="leg" d="M10 10 L20 20 L30 10" />
	<path class="leg" d="M40 10 L50 20 L60 10" />
	</svg></html>`

	status, reason := scheduledTestAnimationQuality(document)
	if status != "unknown" || !strings.Contains(reason, "visual quality requires rendered evaluation") {
		t.Fatalf("rigid pedaling motion = (%q, %q), want inconclusive pending visual review", status, reason)
	}
}
