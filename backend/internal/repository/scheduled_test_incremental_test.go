package repository

import (
	"context"
	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/stretchr/testify/require"
	"testing"
	"time"
)

func TestScheduledResultsIncrementalRetainsQualityMode(t *testing.T) {
	db, mock, err := sqlmock.New()
	require.NoError(t, err)
	defer db.Close()
	now := time.Now()
	mock.ExpectQuery(`WHERE plan_id = \$1 AND id > \$3`).WithArgs(int64(7), 20, int64(100)).
		WillReturnRows(sqlmock.NewRows([]string{"id", "plan_id", "status", "response_text", "error_message", "latency_ms", "started_at", "finished_at", "quality_mode", "created_at"}).
			AddRow(101, 7, "success", "29", "", 100, now, now, "candy", now))
	rows, err := (&scheduledTestResultRepository{db: db}).ListByPlanIDAfter(context.Background(), 7, 20, 100)
	require.NoError(t, err)
	require.Len(t, rows, 1)
	require.Equal(t, "candy", rows[0].QualityMode)
	require.Equal(t, "29", rows[0].ResponseText)
	require.NoError(t, mock.ExpectationsWereMet())
}
