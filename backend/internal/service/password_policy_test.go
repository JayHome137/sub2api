//go:build unit

package service

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestValidateNewPassword(t *testing.T) {
	require.ErrorIs(t, ValidateNewPassword("1234567"), ErrPasswordTooShort)
	require.NoError(t, ValidateNewPassword("12345678"))
	require.NoError(t, ValidateNewPassword("八个字符密码测试值"))
}

func TestUserSetPasswordRejectsShortPassword(t *testing.T) {
	user := &User{PasswordHash: "unchanged"}
	err := user.SetPassword("1234567")
	require.ErrorIs(t, err, ErrPasswordTooShort)
	require.Equal(t, "unchanged", user.PasswordHash)
}
