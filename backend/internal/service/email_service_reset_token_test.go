//go:build unit

package service

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestHashPasswordResetTokenUsesSHA256(t *testing.T) {
	token := "deadbeef"
	sum := sha256.Sum256([]byte(token))
	want := hex.EncodeToString(sum[:])

	require.Equal(t, want, hashPasswordResetToken(token))
	require.NotEqual(t, token, hashPasswordResetToken(token))
	require.Len(t, hashPasswordResetToken(token), sha256.Size*2)
}
