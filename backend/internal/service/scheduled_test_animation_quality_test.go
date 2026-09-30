package service

import (
	"strings"
	"testing"

	"golang.org/x/net/html"
)

func TestScheduledAnimationQualityFlagsRigidPedalingMotion(t *testing.T) {
	const document = `<html><svg>
	<style>
	@keyframes pedal { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
	.leg { animation: pedal 2s infinite; transform-box: fill-box; }
	</style>
	<path class="leg" d="M10 10 L20 20 L30 10" />
	<path class="leg" d="M40 10 L50 20 L60 10" />
	</svg></html>`

	status, reason := scheduledTestAnimationQuality(document)
	if status != "degraded" || !strings.Contains(reason, "rigid shape") {
		t.Fatalf("rigid pedaling motion = (%q, %q), want rigid-leg degradation", status, reason)
	}
}

func TestScheduledAnimationQualityDetectsMorphPathLeavingPedalOrbit(t *testing.T) {
	const document = `<html><style>
.spin { transform-box: fill-box; transform-origin: center; animation: rotateCrank 1.25s linear infinite }
@keyframes rotateCrank { to { transform: rotate(360deg) } }
</style><svg><g class="spin" stroke="black" stroke-width="2"><circle cx="50" cy="50" r="4"/>
<path d="M50 50 L80 50 M50 50 L20 50"/><path d="M80 50 h10 M20 50 h-10"/></g>
<g fill="none" stroke="black" stroke-width="2"><path d="M40 0 L60 25 L80 50"><animate attributeName="d" dur="1.25s" repeatCount="indefinite" values="M40 0 L60 25 L80 50;M40 0 L50 25 L20 50;M40 0 L60 25 L80 50"/></path></g></svg></html>`
	doc, err := html.Parse(strings.NewReader(document))
	if err != nil {
		t.Fatal(err)
	}
	if reason := qualityMorphFailure(doc); !strings.Contains(reason, "pedal orbit") {
		t.Fatalf("morph defect = %q, want pedal-orbit failure", reason)
	}
}
