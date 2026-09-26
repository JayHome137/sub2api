package admin

import (
	"context"

	"github.com/Wei-Shaw/sub2api/internal/service"
)

type ticketHarvestGroupReader struct {
	groups map[int64]*service.Group
}

func (r *ticketHarvestGroupReader) GetByID(_ context.Context, id int64) (*service.Group, error) {
	if group := r.groups[id]; group != nil {
		return group, nil
	}
	return nil, service.ErrGroupNotFound
}
