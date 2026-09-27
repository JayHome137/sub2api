package handler

import (
	"net/http"
	"strconv"

	"github.com/Wei-Shaw/sub2api/internal/pkg/response"
	"github.com/Wei-Shaw/sub2api/internal/server/middleware"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/gin-gonic/gin"
)

// ChannelQualityHandler serves both the admin controls and the user-facing
// read-only quality cards. The route group decides which operations are exposed.
type ChannelQualityHandler struct {
	quality       *service.ChannelQualityService
	apiKeyService *service.APIKeyService
}

func NewChannelQualityHandler(quality *service.ChannelQualityService, apiKeyService *service.APIKeyService) *ChannelQualityHandler {
	return &ChannelQualityHandler{quality: quality, apiKeyService: apiKeyService}
}

func (h *ChannelQualityHandler) GetConfig(c *gin.Context) {
	cfg, err := h.quality.GetConfig(c.Request.Context())
	if err != nil {
		response.ErrorFrom(c, err)
		return
	}
	response.Success(c, cfg)
}

func (h *ChannelQualityHandler) UpdateConfig(c *gin.Context) {
	var cfg service.ChannelQualityConfig
	if err := c.ShouldBindJSON(&cfg); err != nil {
		response.BadRequest(c, "invalid channel quality config")
		return
	}
	updated, err := h.quality.UpdateConfig(c.Request.Context(), cfg)
	if err != nil {
		response.Error(c, http.StatusBadRequest, err.Error())
		return
	}
	response.Success(c, updated)
}

func (h *ChannelQualityHandler) RunNow(c *gin.Context) {
	if err := h.quality.RunNow(c.Request.Context()); err != nil {
		if err == service.ErrChannelQualityConfigConflict {
			response.Error(c, http.StatusConflict, err.Error())
			return
		}
		response.ErrorFrom(c, err)
		return
	}
	response.Success(c, gin.H{"started": true})
}

func (h *ChannelQualityHandler) ListAdmin(c *gin.Context) { h.list(c, true) }
func (h *ChannelQualityHandler) ListUser(c *gin.Context)  { h.list(c, false) }

func (h *ChannelQualityHandler) list(c *gin.Context, admin bool) {
	groupIDs, ok := h.viewerGroupIDs(c, admin)
	if !ok {
		return
	}
	items, err := h.quality.List(c.Request.Context(), groupIDs)
	if err != nil {
		response.ErrorFrom(c, err)
		return
	}
	response.Success(c, gin.H{"items": items})
}

func (h *ChannelQualityHandler) HistoryAdmin(c *gin.Context) { h.history(c, true) }
func (h *ChannelQualityHandler) HistoryUser(c *gin.Context)  { h.history(c, false) }

func (h *ChannelQualityHandler) history(c *gin.Context, admin bool) {
	groupID, err := strconv.ParseInt(c.Param("group_id"), 10, 64)
	if err != nil || groupID <= 0 {
		response.BadRequest(c, "invalid group id")
		return
	}
	if !admin {
		groups, ok := h.viewerGroupIDs(c, false)
		if !ok || !containsInt64(groups, groupID) {
			response.Error(c, http.StatusForbidden, "group is not available")
			return
		}
	}
	limit := 60
	if raw := c.Query("limit"); raw != "" {
		if parsed, parseErr := strconv.Atoi(raw); parseErr == nil {
			limit = parsed
		}
	}
	items, err := h.quality.History(c.Request.Context(), groupID, limit)
	if err != nil {
		response.ErrorFrom(c, err)
		return
	}
	response.Success(c, gin.H{"items": items})
}

func (h *ChannelQualityHandler) viewerGroupIDs(c *gin.Context, admin bool) ([]int64, bool) {
	if admin {
		return nil, true
	}
	if h.apiKeyService == nil {
		response.Error(c, http.StatusInternalServerError, "channel quality group authorization unavailable")
		return nil, false
	}
	subject, ok := middleware.GetAuthSubjectFromContext(c)
	if !ok || subject.UserID <= 0 {
		response.Unauthorized(c, "user not found in context")
		return nil, false
	}
	groups, err := h.apiKeyService.GetAvailableGroups(c.Request.Context(), subject.UserID)
	if err != nil {
		response.ErrorFrom(c, err)
		return nil, false
	}
	ids := make([]int64, 0, len(groups))
	for _, group := range groups {
		ids = append(ids, group.ID)
	}
	return ids, true
}

func containsInt64(values []int64, target int64) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
