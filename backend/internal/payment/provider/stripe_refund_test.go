//go:build unit

package provider

import (
	"context"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/payment"
)

func TestStripeRefundParamsUseStableOrderIdempotencyKey(t *testing.T) {
	request := payment.RefundRequest{
		TradeNo: "pi_123",
		OrderID: "order-1",
		Amount:  "10.25",
	}

	first, err := newStripeRefundParams(context.Background(), request, "USD")
	if err != nil {
		t.Fatalf("newStripeRefundParams() error = %v", err)
	}
	second, err := newStripeRefundParams(context.Background(), request, "USD")
	if err != nil {
		t.Fatalf("newStripeRefundParams() retry error = %v", err)
	}
	if first.IdempotencyKey == nil || *first.IdempotencyKey != "refund-order-1" {
		t.Fatalf("IdempotencyKey = %v, want refund-order-1", first.IdempotencyKey)
	}
	if second.IdempotencyKey == nil || *second.IdempotencyKey != *first.IdempotencyKey {
		t.Fatalf("retry IdempotencyKey = %v, want stable %q", second.IdempotencyKey, *first.IdempotencyKey)
	}
	if first.Amount == nil || *first.Amount != 1025 {
		t.Fatalf("Amount = %v, want 1025", first.Amount)
	}
}

func TestStripeRefundParamsRequireOrderID(t *testing.T) {
	_, err := newStripeRefundParams(context.Background(), payment.RefundRequest{
		TradeNo: "pi_123",
		Amount:  "10.25",
	}, "USD")
	if err == nil {
		t.Fatal("newStripeRefundParams() accepted a missing order id")
	}
}
