package service

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestValidateUsername(t *testing.T) {
	for _, value := range []string{"Alice_1", "张三-测试", "用户.name", "a b"} {
		require.NoError(t, ValidateUsername(value))
	}
	for _, value := range []string{"<svg/onload=x>", "name@example", "a\n b", strings.Repeat("名", MaxUsernameRunes+1)} {
		require.ErrorIs(t, ValidateUsername(value), ErrUsernameInvalid)
	}
}

func TestSanitizeUsername(t *testing.T) {
	require.Equal(t, "alicescriptonloadscript", SanitizeUsername("alice<script>onload</script>"))
	require.Len(t, []rune(SanitizeUsername(strings.Repeat("名", MaxUsernameRunes+5))), MaxUsernameRunes)
}
