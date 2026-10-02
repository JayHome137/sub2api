package repository

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
	"github.com/stretchr/testify/require"
)

func newAtomicEmailCache(t *testing.T) *emailCache {
	t.Helper()
	server := miniredis.RunT(t)
	client := redis.NewClient(&redis.Options{Addr: server.Addr()})
	t.Cleanup(func() { require.NoError(t, client.Close()) })
	return &emailCache{rdb: client}
}

func TestVerifyVerificationCodeConcurrentFailuresAreCountedAtomically(t *testing.T) {
	ctx := context.Background()
	cache := newAtomicEmailCache(t)
	email := "verify@example.com"
	require.NoError(t, cache.SetVerificationCode(ctx, email, &service.VerificationCodeData{
		Code: "123456", ExpiresAt: time.Now().Add(time.Minute),
	}, time.Minute))

	const attempts = 24
	var wg sync.WaitGroup
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, matched, err := cache.VerifyVerificationCode(ctx, email, "wrong", 5)
			require.NoError(t, err)
			require.False(t, matched)
		}()
	}
	wg.Wait()

	data, err := cache.GetVerificationCode(ctx, email)
	require.NoError(t, err)
	require.Equal(t, 5, data.Attempts)
}

func TestVerifyVerificationCodeConsumesCorrectCodeOnce(t *testing.T) {
	ctx := context.Background()
	cache := newAtomicEmailCache(t)
	email := "verify-once@example.com"
	require.NoError(t, cache.SetVerificationCode(ctx, email, &service.VerificationCodeData{Code: "123456"}, time.Minute))

	const workers = 16
	var wg sync.WaitGroup
	var mu sync.Mutex
	successes := 0
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, matched, err := cache.VerifyVerificationCode(ctx, email, "123456", 5)
			if err == nil && matched {
				mu.Lock()
				successes++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	require.Equal(t, 1, successes)
}

func TestConsumePasswordResetTokenIsAtomicAndComparesToken(t *testing.T) {
	ctx := context.Background()
	cache := newAtomicEmailCache(t)
	email := "reset@example.com"
	require.NoError(t, cache.SetPasswordResetToken(ctx, email, &service.PasswordResetTokenData{Token: "secret-token"}, time.Minute))

	consumed, err := cache.ConsumePasswordResetToken(ctx, email, "wrong-token")
	require.NoError(t, err)
	require.False(t, consumed)
	if value, err := cache.GetPasswordResetToken(ctx, email); err != nil {
		t.Fatal(err)
	} else {
		require.Equal(t, "secret-token", value.Token)
	}

	const workers = 16
	var wg sync.WaitGroup
	var mu sync.Mutex
	successes := 0
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			consumed, err := cache.ConsumePasswordResetToken(ctx, email, "secret-token")
			if err == nil && consumed {
				mu.Lock()
				successes++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	require.Equal(t, 1, successes)
}

func TestVerifyVerificationCodePreservesTTL(t *testing.T) {
	ctx := context.Background()
	cache := newAtomicEmailCache(t)
	email := "ttl-verify@example.com"
	require.NoError(t, cache.SetVerificationCode(ctx, email, &service.VerificationCodeData{Code: "123456"}, 2*time.Minute))
	before, err := cache.rdb.PTTL(ctx, verifyCodeKey(email)).Result()
	require.NoError(t, err)

	_, matched, err := cache.VerifyVerificationCode(ctx, email, "wrong", 5)
	require.NoError(t, err)
	require.False(t, matched)
	after, err := cache.rdb.PTTL(ctx, verifyCodeKey(email)).Result()
	require.NoError(t, err)
	require.LessOrEqual(t, after, before)
	require.Greater(t, after, time.Duration(0))

	value, err := cache.rdb.Get(ctx, verifyCodeKey(email)).Bytes()
	require.NoError(t, err)
	var data service.VerificationCodeData
	require.NoError(t, json.Unmarshal(value, &data))
	require.Equal(t, 1, data.Attempts)
}
