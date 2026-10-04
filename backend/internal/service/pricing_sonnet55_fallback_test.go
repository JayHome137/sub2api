package service

import (
	"github.com/stretchr/testify/require"
	"testing"
)

func TestPricingSonnet55AliasesAndFallback(t *testing.T) {
	for _, model := range []string{"claude-sonnet-5-5", "claude-sonnet-5.5", "anthropic/claude-sonnet-5-5-20261001"} {
		t.Run(model, func(t *testing.T) {
			svc := &PricingService{pricingData: map[string]*LiteLLMModelPricing{"claude-sonnet-4-5": {InputCostPerToken: 3e-6}}}
			price := svc.matchByModelFamily(model)
			require.NotNil(t, price)
			require.Equal(t, 2e-6, price.InputCostPerToken)
			require.Equal(t, 10e-6, price.OutputCostPerToken)
			require.Equal(t, 4e-6, price.CacheCreationInputTokenCostAbove1hr)
			custom := &LiteLLMModelPricing{InputCostPerToken: 7e-6}
			svc.pricingData["claude-sonnet-5-5"] = custom
			require.Same(t, custom, svc.matchByModelFamily(model))
		})
	}
}
