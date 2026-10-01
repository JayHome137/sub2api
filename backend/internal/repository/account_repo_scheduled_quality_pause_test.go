package repository

import (
	"context"
	"testing"

	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/lib/pq"
	"github.com/stretchr/testify/require"
)

func TestAccountRepositoryScheduledQualityPauseDoesNotDependOnGroupDisplaySetting(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer func() { _ = db.Close() }()

	repo := newAccountRepositoryWithSQL(nil, db, nil)
	const planID, accountID, groupID = int64(41), int64(27), int64(9)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT id\\s+FROM scheduled_test_plans").
		WithArgs(planID, accountID, "prompt").
		WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(planID))
	mock.ExpectQuery("SELECT true FROM").WithArgs(groupID).
		WillReturnRows(sqlmock.NewRows([]string{"?column?"}).AddRow(true))
	mock.ExpectQuery("SELECT COUNT\\(DISTINCT a.id\\)").WithArgs(groupID, service.StatusActive).
		WillReturnRows(sqlmock.NewRows([]string{"count"}).AddRow(2))
	mock.ExpectExec("UPDATE accounts").
		WithArgs("scheduled quality check: plan=41: degraded", accountID, service.AccountTypeUpstream, pq.Array([]int64{groupID}), service.StatusActive).
		WillReturnResult(sqlmock.NewResult(0, 1))
	mock.ExpectCommit()
	mock.ExpectExec("INSERT INTO scheduler_outbox").
		WithArgs(service.SchedulerOutboxEventAccountChanged, accountID, nil, sqlmock.AnyArg(), sqlmock.AnyArg()).
		WillReturnResult(sqlmock.NewResult(1, 1))

	changed, err := repo.MarkScheduledQualityPause(context.Background(), planID, accountID, "prompt", []int64{groupID}, "scheduled quality check: plan=41: degraded")

	require.NoError(t, err)
	require.True(t, changed)
	require.NoError(t, mock.ExpectationsWereMet())
}
