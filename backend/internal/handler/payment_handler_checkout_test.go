//go:build unit

package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/ent/enttest"
	"github.com/Wei-Shaw/sub2api/internal/repository"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	_ "modernc.org/sqlite"
)

func TestGetCheckoutInfoReturnsErrorWhenPlanQueryFails(t *testing.T) {
	gin.SetMode(gin.TestMode)

	db, err := sql.Open("sqlite", "file:payment_handler_checkout_plan_error?mode=memory&cache=shared")
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })

	_, err = db.Exec("PRAGMA foreign_keys = ON")
	require.NoError(t, err)

	drv := entsql.OpenDB(dialect.SQLite, db)
	client := enttest.NewClient(t, enttest.WithOptions(dbent.Driver(drv)))
	t.Cleanup(func() { _ = client.Close() })

	configSvc := service.NewPaymentConfigService(
		client,
		repository.NewSettingRepository(client),
		[]byte("0123456789abcdef0123456789abcdef"),
	)

	_, err = db.ExecContext(context.Background(), "DROP TABLE subscription_plans")
	require.NoError(t, err)

	recorder := httptest.NewRecorder()
	ctx, _ := gin.CreateTestContext(recorder)
	ctx.Request = httptest.NewRequest(http.MethodGet, "/api/v1/payment/checkout-info", nil)

	NewPaymentHandler(nil, configSvc).GetCheckoutInfo(ctx)

	require.Equal(t, http.StatusInternalServerError, recorder.Code)
	var resp struct {
		Code int `json:"code"`
		Data any `json:"data"`
	}
	require.NoError(t, json.Unmarshal(recorder.Body.Bytes(), &resp))
	require.Equal(t, http.StatusInternalServerError, resp.Code)
	require.Nil(t, resp.Data)
}
