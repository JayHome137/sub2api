//go:build unit

package service

import (
	"context"
	"errors"
	"strconv"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/payment"
	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
	"github.com/stretchr/testify/require"
)

func TestBuildPaymentOrderProviderSnapshot_ExcludesSensitiveConfig(t *testing.T) {
	t.Parallel()

	sel := &payment.InstanceSelection{
		InstanceID:     "12",
		ProviderKey:    payment.TypeWxpay,
		SupportedTypes: "wxpay,wxpay_direct",
		PaymentMode:    "popup",
		Config: map[string]string{
			"privateKey": "secret",
			"apiV3Key":   "secret-v3",
			"appId":      "wx-app-id",
		},
	}

	snapshot := buildPaymentOrderProviderSnapshot(sel, CreateOrderRequest{})
	require.Equal(t, map[string]any{
		"schema_version":       2,
		"provider_instance_id": "12",
		"provider_key":         payment.TypeWxpay,
		"payment_mode":         "popup",
		"merchant_app_id":      "wx-app-id",
		"currency":             "CNY",
	}, snapshot)
	require.NotContains(t, snapshot, "config")
	require.NotContains(t, snapshot, "privateKey")
	require.NotContains(t, snapshot, "apiV3Key")
	require.NotContains(t, snapshot, "supported_types")
	require.NotContains(t, snapshot, "instance_name")
	require.NotContains(t, snapshot, "merchant_id")
}

func TestCreateOrderInTx_WritesProviderSnapshot(t *testing.T) {
	ctx := context.Background()
	client := newPaymentConfigServiceTestClient(t)

	user, err := client.User.Create().
		SetEmail("snapshot@example.com").
		SetPasswordHash("hash").
		SetUsername("snapshot-user").
		Save(ctx)
	require.NoError(t, err)

	instance, err := client.PaymentProviderInstance.Create().
		SetProviderKey(payment.TypeAlipay).
		SetName("Primary Alipay").
		SetConfig(`{"secretKey":"do-not-copy"}`).
		SetSupportedTypes("alipay,alipay_direct").
		SetPaymentMode("redirect").
		SetEnabled(true).
		Save(ctx)
	require.NoError(t, err)

	svc := &PaymentService{entClient: client, loadBalancer: &capacityCaptureLoadBalancer{}}
	order, err := svc.createOrderInTx(
		ctx,
		CreateOrderRequest{
			UserID:      user.ID,
			PaymentType: payment.TypeAlipay,
			OrderType:   payment.OrderTypeBalance,
			ClientIP:    "127.0.0.1",
			SrcHost:     "app.example.com",
		},
		&User{
			ID:       user.ID,
			Email:    user.Email,
			Username: user.Username,
		},
		nil,
		&PaymentConfig{
			MaxPendingOrders: 3,
			OrderTimeoutMin:  30,
		},
		88,
		88,
		0,
		88,
		&payment.InstanceSelection{
			InstanceID:     strconv.FormatInt(instance.ID, 10),
			ProviderKey:    payment.TypeAlipay,
			SupportedTypes: "alipay,alipay_direct",
			PaymentMode:    "redirect",
			Config: map[string]string{
				"secretKey": "do-not-copy",
			},
		},
	)
	require.NoError(t, err)
	require.Equal(t, strconv.FormatInt(instance.ID, 10), valueOrEmpty(order.ProviderInstanceID))
	require.Equal(t, payment.TypeAlipay, valueOrEmpty(order.ProviderKey))
	require.Equal(t, float64(2), order.ProviderSnapshot["schema_version"])
	require.Equal(t, strconv.FormatInt(instance.ID, 10), order.ProviderSnapshot["provider_instance_id"])
	require.Equal(t, payment.TypeAlipay, order.ProviderSnapshot["provider_key"])
	require.Equal(t, "redirect", order.ProviderSnapshot["payment_mode"])
	require.NotContains(t, order.ProviderSnapshot, "config")
	require.NotContains(t, order.ProviderSnapshot, "secretKey")
	require.NotContains(t, order.ProviderSnapshot, "supported_types")
	require.NotContains(t, order.ProviderSnapshot, "instance_name")
}

func TestCreateOrderInTxMapsMissingCapacityReservationToServiceUnavailable(t *testing.T) {
	ctx := context.Background()
	client := newPaymentConfigServiceTestClient(t)
	svc := &PaymentService{
		entClient:    client,
		loadBalancer: &visibleMethodLoadBalancer{inner: &captureLoadBalancer{}},
	}

	order, err := svc.createOrderInTx(
		ctx,
		CreateOrderRequest{
			UserID:      1,
			PaymentType: payment.TypeAlipay,
			OrderType:   payment.OrderTypeBalance,
		},
		&User{ID: 1, Email: "capacity@example.com", Username: "capacity-user"},
		nil,
		&PaymentConfig{MaxPendingOrders: 3, OrderTimeoutMin: 30},
		10,
		0,
		0,
		10,
		&payment.InstanceSelection{InstanceID: "7", ProviderKey: payment.TypeAlipay},
	)

	require.Nil(t, order)
	require.Error(t, err)
	require.Equal(t, 503, infraerrors.Code(err))
	require.Equal(t, "PAYMENT_CAPACITY_RESERVATION_UNAVAILABLE", infraerrors.Reason(err))
	require.True(t, errors.Is(err, payment.ErrInstanceCapacityReservationUnavailable))
	count, countErr := client.PaymentOrder.Query().Count(ctx)
	require.NoError(t, countErr)
	require.Zero(t, count, "capacity reservation failure must not create an order")
}

func TestBuildPaymentOrderProviderSnapshot_UsesWxpayJSAPIAppIDForOpenIDOrders(t *testing.T) {
	t.Parallel()

	snapshot := buildPaymentOrderProviderSnapshot(&payment.InstanceSelection{
		InstanceID:  "88",
		ProviderKey: payment.TypeWxpay,
		Config: map[string]string{
			"appId":   "wx-open-app",
			"mpAppId": "wx-mp-app",
			"mchId":   "mch-88",
		},
		PaymentMode: "jsapi",
	}, CreateOrderRequest{OpenID: "openid-123"})

	require.Equal(t, "wx-mp-app", snapshot["merchant_app_id"])
	require.Equal(t, "mch-88", snapshot["merchant_id"])
	require.Equal(t, "CNY", snapshot["currency"])
}

func TestBuildPaymentOrderProviderSnapshot_IncludesAlipayMerchantIdentity(t *testing.T) {
	t.Parallel()

	snapshot := buildPaymentOrderProviderSnapshot(&payment.InstanceSelection{
		InstanceID:  "21",
		ProviderKey: payment.TypeAlipay,
		Config: map[string]string{
			"appId":      "alipay-app-21",
			"privateKey": "secret",
		},
		PaymentMode: "redirect",
	}, CreateOrderRequest{})

	require.Equal(t, "alipay-app-21", snapshot["merchant_app_id"])
	require.NotContains(t, snapshot, "privateKey")
}

func TestBuildPaymentOrderProviderSnapshot_IncludesEasyPayMerchantIdentity(t *testing.T) {
	t.Parallel()

	snapshot := buildPaymentOrderProviderSnapshot(&payment.InstanceSelection{
		InstanceID:  "66",
		ProviderKey: payment.TypeEasyPay,
		Config: map[string]string{
			"pid":  "easypay-merchant-66",
			"pkey": "secret",
		},
		PaymentMode: "popup",
	}, CreateOrderRequest{PaymentType: payment.TypeAlipay})

	require.Equal(t, "easypay-merchant-66", snapshot["merchant_id"])
	require.NotContains(t, snapshot, "pkey")
}

func TestBuildPaymentOrderProviderSnapshot_IncludesProviderCurrency(t *testing.T) {
	t.Parallel()

	stripeSnapshot := buildPaymentOrderProviderSnapshot(&payment.InstanceSelection{
		InstanceID:  "77",
		ProviderKey: payment.TypeStripe,
		Config: map[string]string{
			"currency": "hkd",
		},
	}, CreateOrderRequest{})
	require.Equal(t, "HKD", stripeSnapshot["currency"])

	airwallexSnapshot := buildPaymentOrderProviderSnapshot(&payment.InstanceSelection{
		InstanceID:  "78",
		ProviderKey: payment.TypeAirwallex,
		Config: map[string]string{
			"currency":  "usd",
			"accountId": "acct-78",
		},
	}, CreateOrderRequest{})
	require.Equal(t, "USD", airwallexSnapshot["currency"])
	require.Equal(t, "acct-78", airwallexSnapshot["merchant_id"])
}

func valueOrEmpty(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}
