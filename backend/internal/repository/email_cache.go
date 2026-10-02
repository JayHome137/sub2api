package repository

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/redis/go-redis/v9"
)

const (
	verifyCodeKeyPrefix          = "verify_code:"
	notifyVerifyKeyPrefix        = "notify_verify:"
	passwordResetKeyPrefix       = "password_reset:"
	passwordResetSentAtKeyPrefix = "password_reset_sent:"
	notifyCodeUserRateKeyPrefix  = "notify_code_user_rate:"
)

// verifyCodeKey generates the Redis key for email verification code.
// Email is lowercased for case-insensitive consistency.
func verifyCodeKey(email string) string {
	return verifyCodeKeyPrefix + strings.ToLower(email)
}

// notifyVerifyKey generates the Redis key for notify email verification code.
// Email is lowercased to prevent case-sensitive key mismatch (the business layer
// uses strings.EqualFold for comparison).
func notifyVerifyKey(email string) string {
	return notifyVerifyKeyPrefix + strings.ToLower(email)
}

// passwordResetKey generates the Redis key for password reset token.
func passwordResetKey(email string) string {
	return passwordResetKeyPrefix + strings.ToLower(email)
}

// passwordResetSentAtKey generates the Redis key for password reset email sent timestamp.
func passwordResetSentAtKey(email string) string {
	return passwordResetSentAtKeyPrefix + strings.ToLower(email)
}

type emailCache struct {
	rdb *redis.Client
}

func NewEmailCache(rdb *redis.Client) service.EmailCache {
	return &emailCache{rdb: rdb}
}

func (c *emailCache) GetVerificationCode(ctx context.Context, email string) (*service.VerificationCodeData, error) {
	key := verifyCodeKey(email)
	val, err := c.rdb.Get(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	var data service.VerificationCodeData
	if err := json.Unmarshal([]byte(val), &data); err != nil {
		return nil, err
	}
	return &data, nil
}

func (c *emailCache) SetVerificationCode(ctx context.Context, email string, data *service.VerificationCodeData, ttl time.Duration) error {
	key := verifyCodeKey(email)
	val, err := json.Marshal(data)
	if err != nil {
		return err
	}
	return c.rdb.Set(ctx, key, val, ttl).Err()
}

func (c *emailCache) DeleteVerificationCode(ctx context.Context, email string) error {
	key := verifyCodeKey(email)
	return c.rdb.Del(ctx, key).Err()
}

// VerifyVerificationCode updates failed attempts or consumes a correct code atomically.
func (c *emailCache) VerifyVerificationCode(ctx context.Context, email, code string, maxAttempts int) (attempts int, matched bool, err error) {
	key := verifyCodeKey(email)
	for retry := 0; retry < 8; retry++ {
		attempts = 0
		matched = false
		err = c.rdb.Watch(ctx, func(tx *redis.Tx) error {
			value, getErr := tx.Get(ctx, key).Result()
			if getErr != nil {
				return getErr
			}
			var data service.VerificationCodeData
			if err := json.Unmarshal([]byte(value), &data); err != nil {
				return err
			}
			attempts = data.Attempts
			if data.Attempts >= maxAttempts {
				return nil
			}

			if subtle.ConstantTimeCompare([]byte(data.Code), []byte(code)) == 1 {
				_, err := tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
					pipe.Del(ctx, key)
					return nil
				})
				if err == nil {
					matched = true
				}
				return err
			}

			ttl, err := tx.PTTL(ctx, key).Result()
			if err != nil {
				return err
			}
			if ttl <= 0 {
				return redis.Nil
			}
			data.Attempts++
			attempts = data.Attempts
			updated, err := json.Marshal(&data)
			if err != nil {
				return err
			}
			_, err = tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
				pipe.Set(ctx, key, updated, ttl)
				return nil
			})
			return err
		}, key)
		if errors.Is(err, redis.TxFailedErr) {
			continue
		}
		return attempts, matched, err
	}
	return attempts, false, errors.New("verification code changed too frequently")
}

// Password reset token methods

func (c *emailCache) GetPasswordResetToken(ctx context.Context, email string) (*service.PasswordResetTokenData, error) {
	key := passwordResetKey(email)
	val, err := c.rdb.Get(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	var data service.PasswordResetTokenData
	if err := json.Unmarshal([]byte(val), &data); err != nil {
		return nil, err
	}
	return &data, nil
}

func (c *emailCache) SetPasswordResetToken(ctx context.Context, email string, data *service.PasswordResetTokenData, ttl time.Duration) error {
	key := passwordResetKey(email)
	val, err := json.Marshal(data)
	if err != nil {
		return err
	}
	return c.rdb.Set(ctx, key, val, ttl).Err()
}

func (c *emailCache) DeletePasswordResetToken(ctx context.Context, email string) error {
	key := passwordResetKey(email)
	return c.rdb.Del(ctx, key).Err()
}

// ConsumePasswordResetToken compares and deletes a reset token in one transaction.
func (c *emailCache) ConsumePasswordResetToken(ctx context.Context, email, token string) (consumed bool, err error) {
	key := passwordResetKey(email)
	for retry := 0; retry < 8; retry++ {
		consumed = false
		err = c.rdb.Watch(ctx, func(tx *redis.Tx) error {
			value, getErr := tx.Get(ctx, key).Result()
			if getErr != nil {
				return getErr
			}
			var data service.PasswordResetTokenData
			if err := json.Unmarshal([]byte(value), &data); err != nil {
				return err
			}
			if subtle.ConstantTimeCompare([]byte(data.Token), []byte(token)) != 1 {
				return nil
			}
			_, err := tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
				pipe.Del(ctx, key)
				return nil
			})
			if err == nil {
				consumed = true
			}
			return err
		}, key)
		if errors.Is(err, redis.TxFailedErr) {
			continue
		}
		return consumed, err
	}
	return false, errors.New("password reset token changed too frequently")
}

// Password reset email cooldown methods

func (c *emailCache) IsPasswordResetEmailInCooldown(ctx context.Context, email string) bool {
	key := passwordResetSentAtKey(email)
	exists, err := c.rdb.Exists(ctx, key).Result()
	return err == nil && exists > 0
}

func (c *emailCache) SetPasswordResetEmailCooldown(ctx context.Context, email string, ttl time.Duration) error {
	key := passwordResetSentAtKey(email)
	return c.rdb.Set(ctx, key, "1", ttl).Err()
}

// Notify email verification code methods

func (c *emailCache) GetNotifyVerifyCode(ctx context.Context, email string) (*service.VerificationCodeData, error) {
	key := notifyVerifyKey(email)
	val, err := c.rdb.Get(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	var data service.VerificationCodeData
	if err := json.Unmarshal([]byte(val), &data); err != nil {
		return nil, err
	}
	return &data, nil
}

func (c *emailCache) SetNotifyVerifyCode(ctx context.Context, email string, data *service.VerificationCodeData, ttl time.Duration) error {
	key := notifyVerifyKey(email)
	val, err := json.Marshal(data)
	if err != nil {
		return err
	}
	return c.rdb.Set(ctx, key, val, ttl).Err()
}

func (c *emailCache) DeleteNotifyVerifyCode(ctx context.Context, email string) error {
	key := notifyVerifyKey(email)
	return c.rdb.Del(ctx, key).Err()
}

// User-level rate limiting for notify email verification codes

func notifyCodeUserRateKey(userID int64) string {
	return notifyCodeUserRateKeyPrefix + fmt.Sprintf("%d", userID)
}

func (c *emailCache) IncrNotifyCodeUserRate(ctx context.Context, userID int64, window time.Duration) (int64, error) {
	key := notifyCodeUserRateKey(userID)
	count, err := c.rdb.Incr(ctx, key).Result()
	if err != nil {
		return 0, err
	}
	// Always set TTL (idempotent) to avoid orphan keys if process crashes between INCR and EXPIRE.
	if err := c.rdb.Expire(ctx, key, window).Err(); err != nil {
		return count, fmt.Errorf("expire notify code rate key: %w", err)
	}
	return count, nil
}

func (c *emailCache) GetNotifyCodeUserRate(ctx context.Context, userID int64) (int64, error) {
	key := notifyCodeUserRateKey(userID)
	count, err := c.rdb.Get(ctx, key).Int64()
	if err != nil {
		return 0, err
	}
	return count, nil
}
