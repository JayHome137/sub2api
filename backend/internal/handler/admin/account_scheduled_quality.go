package admin

import (
	"strconv"

	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

type scheduledQualityAutoPauseRequest struct {
	Enabled *bool `json:"enabled" binding:"required"`
}

func (h *AccountHandler) SetScheduledQualityAutoPause(c *gin.Context) {
	accountID, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || accountID <= 0 {
		response.BadRequest(c, "Invalid account ID")
		return
	}
	var req scheduledQualityAutoPauseRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		response.BadRequest(c, "Invalid request: "+err.Error())
		return
	}
	if err := h.adminService.UpdateAccountExtra(c.Request.Context(), accountID, map[string]any{
		service.ScheduledQualityAutoPauseEnabledExtraKey: *req.Enabled,
	}); err != nil {
		response.ErrorFrom(c, err)
		return
	}
	response.Success(c, gin.H{"account_id": accountID, "enabled": *req.Enabled})
}
