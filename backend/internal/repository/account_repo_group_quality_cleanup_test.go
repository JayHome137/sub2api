package repository

import (
	"context"
	"testing"

	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

func TestAccountRepository_ClearScheduledQualityPausesForDisabledGroupSkipsAfterReenable(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer func() { _ = db.Close() }()

	repo := newAccountRepositoryWithSQL(nil, db, nil)
	groupID := int64(77)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT true FROM").WithArgs(groupID).
		WillReturnRows(sqlmock.NewRows([]string{"?column?"}).AddRow(true))
	mock.ExpectQuery("SELECT enabled FROM group_quality_check_settings").WithArgs(groupID).
		WillReturnRows(sqlmock.NewRows([]string{"enabled"}).AddRow(true))
	mock.ExpectRollback()

	err = repo.ClearScheduledQualityPausesForDisabledGroup(context.Background(), groupID)

	require.NoError(t, err)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestAccountRepository_ClearScheduledQualityPausesForDisabledGroupUsesGuardedCleanup(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer func() { _ = db.Close() }()

	repo := newAccountRepositoryWithSQL(nil, db, nil)
	groupID := int64(77)
	mock.ExpectBegin()
	mock.ExpectQuery("SELECT true FROM").WithArgs(groupID).
		WillReturnRows(sqlmock.NewRows([]string{"?column?"}).AddRow(true))
	mock.ExpectQuery("SELECT enabled FROM group_quality_check_settings").WithArgs(groupID).
		WillReturnRows(sqlmock.NewRows([]string{"enabled"}).AddRow(false))
	mock.ExpectQuery(`(?s)UPDATE accounts AS a.*NOT EXISTS.*group_quality_check_settings.*RETURNING a.id`).
		WithArgs(groupID).
		WillReturnRows(sqlmock.NewRows([]string{"id"}).AddRow(int64(12)))
	mock.ExpectCommit()
	mock.ExpectExec("INSERT INTO scheduler_outbox").
		WithArgs(service.SchedulerOutboxEventAccountChanged, int64(12), nil, nil, sqlmock.AnyArg()).
		WillReturnResult(sqlmock.NewResult(1, 1))

	err = repo.ClearScheduledQualityPausesForDisabledGroup(context.Background(), groupID)

	require.NoError(t, err)
	require.NoError(t, mock.ExpectationsWereMet())
}
