package repository

import (
	"context"
	"regexp"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/stretchr/testify/require"
)

func TestGetBillingAnomalySnapshotReadOnlyAggregates(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer db.Close()

	start := time.Date(2026, 10, 3, 10, 0, 0, 0, time.UTC)
	end := start.Add(5 * time.Minute)
	mock.ExpectQuery(regexp.QuoteMeta("FROM usage_logs\nWHERE created_at >= $3 AND created_at < $2")).
		WithArgs(start, end, start.Add(-5*time.Minute)).
		WillReturnRows(sqlmock.NewRows([]string{"metered", "zero_cost", "previous_zero", "window_cost", "previous_cost"}).AddRow(20, 3, 1, 4.5, 3.0))
	mock.ExpectQuery(regexp.QuoteMeta("SELECT COUNT(*) FROM users WHERE balance < 0 AND deleted_at IS NULL")).
		WillReturnRows(sqlmock.NewRows([]string{"count"}).AddRow(2))

	repo := &opsRepository{db: db}
	snapshot, err := repo.GetBillingAnomalySnapshot(context.Background(), start, end)
	require.NoError(t, err)
	require.Equal(t, int64(20), snapshot.MeteredRequests)
	require.Equal(t, int64(3), snapshot.ZeroCostRequests)
	require.Equal(t, int64(1), snapshot.PreviousWindowZeroCostRequests)
	require.Equal(t, 4.5, snapshot.WindowCostUSD)
	require.Equal(t, 3.0, snapshot.PreviousWindowCostUSD)
	require.Equal(t, int64(2), snapshot.NegativeBalanceUsers)
	require.NoError(t, mock.ExpectationsWereMet())
}

func TestGetBillingAnomalySnapshotRejectsInvalidWindow(t *testing.T) {
	db, _, err := sqlmock.New()
	require.NoError(t, err)
	defer db.Close()

	repo := &opsRepository{db: db}
	_, err = repo.GetBillingAnomalySnapshot(context.Background(), time.Now(), time.Now())
	require.Error(t, err)
}
