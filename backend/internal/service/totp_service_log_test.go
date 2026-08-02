//go:build unit

package service

import (
	"bytes"
	"context"
	"log/slog"
	"testing"
	"time"

	"github.com/pquerna/otp/totp"
	"github.com/stretchr/testify/require"
)

type totpLogUserRepoStub struct {
	UserRepository
	user *User
}

func (s *totpLogUserRepoStub) GetByID(context.Context, int64) (*User, error) {
	return s.user, nil
}

func (s *totpLogUserRepoStub) UpdateTotpSecret(_ context.Context, _ int64, encryptedSecret *string) error {
	s.user.TotpSecretEncrypted = encryptedSecret
	return nil
}

func (s *totpLogUserRepoStub) EnableTotp(context.Context, int64) error {
	s.user.TotpEnabled = true
	return nil
}

type totpLogCacheStub struct {
	TotpCache
	setupSession *TotpSetupSession
}

func (s *totpLogCacheStub) GetSetupSession(context.Context, int64) (*TotpSetupSession, error) {
	return s.setupSession, nil
}

func (s *totpLogCacheStub) DeleteSetupSession(context.Context, int64) error {
	s.setupSession = nil
	return nil
}

func (s *totpLogCacheStub) GetVerifyAttempts(context.Context, int64) (int, error) {
	return 0, nil
}

func (s *totpLogCacheStub) IncrementVerifyAttempts(context.Context, int64) (int, error) {
	return 1, nil
}

func (s *totpLogCacheStub) ClearVerifyAttempts(context.Context, int64) error {
	return nil
}

type totpLogEncryptorStub struct {
	secret string
}

func (s *totpLogEncryptorStub) Encrypt(string) (string, error) {
	return "encrypted-value", nil
}

func (s *totpLogEncryptorStub) Decrypt(string) (string, error) {
	return s.secret, nil
}

type totpLogSettingRepoStub struct {
	SettingRepository
}

func (s *totpLogSettingRepoStub) GetValue(_ context.Context, key string) (string, error) {
	if key == SettingKeyTotpEnabled {
		return "true", nil
	}
	return "", ErrSettingNotFound
}

func TestTotpDebugLogsDoNotContainSecretMaterial(t *testing.T) {
	const secret = "JBSWY3DPEHPK3PXP"
	const setupToken = "setup-token"

	var output bytes.Buffer
	previousLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&output, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previousLogger) })

	code, err := totp.GenerateCode(secret, time.Now())
	require.NoError(t, err)

	userRepo := &totpLogUserRepoStub{user: &User{ID: 7, Email: "user@example.com"}}
	cache := &totpLogCacheStub{setupSession: &TotpSetupSession{
		Secret:     secret,
		SetupToken: setupToken,
		CreatedAt:  time.Now(),
	}}
	settingService := NewSettingService(&totpLogSettingRepoStub{}, nil)
	service := NewTotpService(
		userRepo,
		&totpLogEncryptorStub{secret: secret},
		cache,
		settingService,
		nil,
		nil,
	)

	require.NoError(t, service.CompleteSetup(context.Background(), userRepo.user.ID, code, setupToken))
	require.NoError(t, service.VerifyCode(context.Background(), userRepo.user.ID, code))

	logs := output.String()
	require.NotContains(t, logs, secret)
	require.NotContains(t, logs, secret[:4])
	require.NotContains(t, logs, "secret_prefix")
	require.NotContains(t, logs, "decrypted_prefix")
	require.Contains(t, logs, "secret_len")
	require.Contains(t, logs, "valid=true")
}
