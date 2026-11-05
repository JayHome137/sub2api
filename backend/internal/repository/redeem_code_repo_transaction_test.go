package repository

import (
	"context"
	"database/sql"
	"fmt"
	"testing"
	"time"

	"entgo.io/ent/dialect"
	entsql "entgo.io/ent/dialect/sql"
	dbent "github.com/Wei-Shaw/sub2api/ent"
	"github.com/Wei-Shaw/sub2api/ent/enttest"
	"github.com/Wei-Shaw/sub2api/ent/redeemcode"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"
)

func TestRedeemCodeRepositoryCreateUsesTransactionFromContext(t *testing.T) {
	db, err := sql.Open("sqlite", fmt.Sprintf("file:%s?mode=memory&cache=shared&_fk=1&_pragma=foreign_keys(1)", t.Name()))
	require.NoError(t, err)
	t.Cleanup(func() { _ = db.Close() })
	db.SetMaxOpenConns(4)

	client := enttest.NewClient(t, enttest.WithOptions(dbent.Driver(entsql.OpenDB(dialect.SQLite, db))))
	t.Cleanup(func() { _ = client.Close() })
	repo := NewRedeemCodeRepository(client).(*redeemCodeRepository)
	ctx := context.Background()
	user, err := client.User.Create().SetEmail("transactional-source@example.com").SetPasswordHash("test-hash").Save(ctx)
	require.NoError(t, err)

	tx, err := client.Tx(ctx)
	require.NoError(t, err)
	txCtx := dbent.NewTxContext(ctx, tx)
	usedAt := time.Now()
	code := &service.RedeemCode{
		Code: "transactional-source", Type: "admin_balance", Value: 5,
		Status: service.StatusUsed, UsedBy: &user.ID, UsedAt: &usedAt,
	}
	require.NoError(t, repo.Create(txCtx, code))
	require.NoError(t, tx.Rollback())

	count, err := client.RedeemCode.Query().Where(redeemcode.CodeEQ(code.Code)).Count(ctx)
	require.NoError(t, err)
	require.Zero(t, count, "source record must roll back with its balance transaction")
}
