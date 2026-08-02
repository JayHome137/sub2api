package service

import (
	"context"
	"errors"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
)

type failingSelectionLoadBalancer struct {
	err error
}

func (f *failingSelectionLoadBalancer) GetInstanceConfig(context.Context, int64) (map[string]string, error) {
	return nil, f.err
}

func (f *failingSelectionLoadBalancer) SelectInstance(
	context.Context,
	string,
	payment.PaymentType,
	payment.Strategy,
	float64,
) (*payment.InstanceSelection, error) {
	return nil, f.err
}

func TestSelectCreateOrderInstanceMapsLimitExhaustion(t *testing.T) {
	svc := &PaymentService{
		loadBalancer: &failingSelectionLoadBalancer{
			err: payment.ErrInstanceLimitsExhausted,
		},
	}

	selection, err := svc.selectCreateOrderInstance(
		context.Background(),
		CreateOrderRequest{PaymentType: payment.TypeAlipay},
		&PaymentConfig{},
		100,
	)

	if selection != nil {
		t.Fatalf("selection = %#v, want nil", selection)
	}
	if got := infraerrors.Reason(err); got != "NO_AVAILABLE_INSTANCE" {
		t.Fatalf("error reason = %q, want NO_AVAILABLE_INSTANCE", got)
	}
}

func TestSelectCreateOrderInstancePreservesUnexpectedCause(t *testing.T) {
	selectionCause := errors.New("daily usage query unavailable")
	svc := &PaymentService{
		loadBalancer: &failingSelectionLoadBalancer{err: selectionCause},
	}

	selection, err := svc.selectCreateOrderInstance(
		context.Background(),
		CreateOrderRequest{PaymentType: payment.TypeAlipay},
		&PaymentConfig{},
		100,
	)

	if selection != nil {
		t.Fatalf("selection = %#v, want nil", selection)
	}
	if got := infraerrors.Reason(err); got != "PAYMENT_GATEWAY_ERROR" {
		t.Fatalf("error reason = %q, want PAYMENT_GATEWAY_ERROR", got)
	}
	if !errors.Is(err, selectionCause) {
		t.Fatalf("error = %v, want wrapped selection cause", err)
	}
}
