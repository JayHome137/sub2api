//go:build unit

package service

import (
	"context"
	"errors"
	"strconv"
	"testing"

	"github.com/Wei-Shaw/sub2api/ent/paymentauditlog"
	"github.com/Wei-Shaw/sub2api/internal/payment"
	"github.com/stretchr/testify/require"
)

func TestRollbackRefundRecordsSourceAndIsIdempotent(t *testing.T) {
	ctx := context.Background()
	client := newPaymentConfigServiceTestClient(t)
	order := createPendingRefundOrderForTest(t, ctx, client, "balance-rollback-idempotent")
	_, err := client.User.UpdateOneID(order.UserID).SetBalance(10).Save(ctx)
	require.NoError(t, err)
	plan := &RefundPlan{
		OrderID: order.ID, Order: order, RefundAmount: 5, GatewayAmount: 5,
		Reason: "gateway rejected", Force: true,
		DeductionType: payment.DeductionTypeBalance, BalanceToDeduct: 5,
	}
	svc := &PaymentService{entClient: client, userRepo: &transactionalBalanceUserRepo{client: client}}

	require.True(t, svc.RollbackRefund(ctx, plan, errors.New("provider unavailable")))
	require.True(t, svc.RollbackRefund(ctx, plan, errors.New("provider unavailable")))

	updated, err := client.User.Get(ctx, order.UserID)
	require.NoError(t, err)
	require.Equal(t, 15.0, updated.Balance, "replaying the same refund rollback must not credit twice")
	audit, err := client.PaymentAuditLog.Query().
		Where(paymentauditlog.OrderIDEQ(strconv.FormatInt(plan.OrderID, 10)), paymentauditlog.ActionEQ(refundBalanceRollbackAction(plan))).
		Only(ctx)
	require.NoError(t, err)
	require.Contains(t, audit.Detail, `"balanceReturned":5`)
	require.Contains(t, audit.Detail, `"source":"refund_gateway_failure"`)
}
