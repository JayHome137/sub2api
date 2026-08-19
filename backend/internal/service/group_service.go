package service

import (
	"context"

	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
	"github.com/Wei-Shaw/sub2api/internal/pkg/pagination"
)

var (
	ErrGroupNotFound = infraerrors.NotFound("GROUP_NOT_FOUND", "group not found")
	ErrGroupExists   = infraerrors.Conflict("GROUP_EXISTS", "group name already exists")
)

type GroupRepository interface {
	Create(ctx context.Context, group *Group) error
	GetByID(ctx context.Context, id int64) (*Group, error)
	GetByIDLite(ctx context.Context, id int64) (*Group, error)
	Update(ctx context.Context, group *Group) error
	Delete(ctx context.Context, id int64) error
	DeleteCascade(ctx context.Context, id int64) ([]int64, error)

	List(ctx context.Context, params pagination.PaginationParams) ([]Group, *pagination.PaginationResult, error)
	ListWithFilters(ctx context.Context, params pagination.PaginationParams, platform, status, search string, isExclusive *bool) ([]Group, *pagination.PaginationResult, error)
	ListActive(ctx context.Context) ([]Group, error)
	ListActiveByPlatform(ctx context.Context, platform string) ([]Group, error)

	ExistsByName(ctx context.Context, name string) (bool, error)
	GetAccountCount(ctx context.Context, groupID int64) (total int64, active int64, err error)
	DeleteAccountGroupsByGroupID(ctx context.Context, groupID int64) (int64, error)
	// GetAccountIDsByGroupIDs 获取多个分组的所有账号 ID（去重）
	GetAccountIDsByGroupIDs(ctx context.Context, groupIDs []int64) ([]int64, error)
	// BindAccountsToGroup 将多个账号绑定到指定分组
	BindAccountsToGroup(ctx context.Context, groupID int64, accountIDs []int64) error
	// UpdateSortOrders 批量更新分组排序
	UpdateSortOrders(ctx context.Context, updates []GroupSortOrderUpdate) error
}

type GroupDuplicateRepository interface {
	// FindByDuplicateOperationID performs the read-only recovery lookup used
	// after an ambiguous idempotency-store failure.
	FindByDuplicateOperationID(ctx context.Context, operationID string) (*Group, error)
	// CreateFromSource atomically persists the group, copies the source group's
	// exact account priorities, and writes the scheduler outbox event.
	CreateFromSource(ctx context.Context, group *Group, sourceGroupID int64) error
}

// AdminGroupRepository makes the group-duplication write capability an explicit
// admin-service dependency without widening gateway-only group test doubles.
type AdminGroupRepository interface {
	GroupRepository
	GroupDuplicateRepository
}

// GroupSortOrderUpdate 分组排序更新
type GroupSortOrderUpdate struct {
	ID        int64 `json:"id"`
	SortOrder int   `json:"sort_order"`
}

// CreateGroupRequest 创建分组请求
type CreateGroupRequest struct {
	Name                 string   `json:"name"`
	Description          string   `json:"description"`
	RateMultiplier       float64  `json:"rate_multiplier"`
	IsExclusive          bool     `json:"is_exclusive"`
	AllowImageGeneration bool     `json:"allow_image_generation"`
	ImageRateIndependent bool     `json:"image_rate_independent"`
	ImageRateMultiplier  *float64 `json:"image_rate_multiplier"`
}

// UpdateGroupRequest 更新分组请求
type UpdateGroupRequest struct {
	Name                 *string  `json:"name"`
	Description          *string  `json:"description"`
	RateMultiplier       *float64 `json:"rate_multiplier"`
	IsExclusive          *bool    `json:"is_exclusive"`
	Status               *string  `json:"status"`
	AllowImageGeneration *bool    `json:"allow_image_generation"`
	ImageRateIndependent *bool    `json:"image_rate_independent"`
	ImageRateMultiplier  *float64 `json:"image_rate_multiplier"`
}
