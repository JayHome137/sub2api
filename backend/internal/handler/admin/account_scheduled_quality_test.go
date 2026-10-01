package admin

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

func TestAccountHandlerSetScheduledQualityAutoPause(t *testing.T) {
	gin.SetMode(gin.TestMode)
	adminSvc := newStubAdminService()
	handler := NewAccountHandler(adminSvc, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
	router := gin.New()
	router.PUT("/admin/accounts/:id/scheduled-quality-auto-pause", handler.SetScheduledQualityAutoPause)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPut, "/admin/accounts/17/scheduled-quality-auto-pause", bytes.NewBufferString(`{"enabled":false}`))
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, request)

	require.Equal(t, http.StatusOK, recorder.Code)
	require.Equal(t, 1, adminSvc.updateAccountExtraCalls)
	require.Equal(t, map[string]any{service.ScheduledQualityAutoPauseEnabledExtraKey: false}, adminSvc.lastUpdateAccountExtra)
}

func TestAccountHandlerSetScheduledQualityAutoPauseRequiresBoolean(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := NewAccountHandler(newStubAdminService(), nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
	router := gin.New()
	router.PUT("/admin/accounts/:id/scheduled-quality-auto-pause", handler.SetScheduledQualityAutoPause)
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPut, "/admin/accounts/17/scheduled-quality-auto-pause", bytes.NewBufferString(`{}`))
	request.Header.Set("Content-Type", "application/json")
	router.ServeHTTP(recorder, request)

	require.Equal(t, http.StatusBadRequest, recorder.Code)
}
