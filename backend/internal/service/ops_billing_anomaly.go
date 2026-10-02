package service

import "time"

const (
	OpsMetricBillingZeroCostRequests      = "billing_zero_cost_requests"
	OpsMetricBillingZeroCostRatio         = "billing_zero_cost_ratio"
	OpsMetricBillingZeroCostRequestsDelta = "billing_zero_cost_requests_delta"
	OpsMetricBillingCostSpikeRatio        = "billing_cost_spike_ratio"
	OpsMetricBillingNegativeBalanceUsers  = "billing_negative_balance_users"
	OpsMetricBillingNegativeBalanceDelta  = "billing_negative_balance_users_delta"
)

const opsBillingMetricMaxWindow = 6 * time.Hour

// BillingAnomalySnapshot contains read-only aggregates for one and the preceding window.
type BillingAnomalySnapshot struct {
	MeteredRequests                int64
	ZeroCostRequests               int64
	PreviousWindowZeroCostRequests int64
	WindowCostUSD                  float64
	PreviousWindowCostUSD          float64
	NegativeBalanceUsers           int64
}

func (s *BillingAnomalySnapshot) ZeroCostRatio() float64 {
	if s == nil || s.MeteredRequests <= 0 {
		return 0
	}
	return float64(s.ZeroCostRequests) / float64(s.MeteredRequests) * 100
}

func (s *BillingAnomalySnapshot) ZeroCostRequestDelta() float64 {
	if s == nil {
		return 0
	}
	return float64(s.ZeroCostRequests - s.PreviousWindowZeroCostRequests)
}

func (s *BillingAnomalySnapshot) CostSpikeRatio() (float64, bool) {
	if s == nil || s.PreviousWindowCostUSD <= 0 {
		return 0, false
	}
	return s.WindowCostUSD / s.PreviousWindowCostUSD * 100, true
}
