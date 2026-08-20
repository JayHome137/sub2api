package repository

import (
	"errors"
	"testing"

	"github.com/lib/pq"
	"github.com/stretchr/testify/require"
)

func TestAPIKeyCredentialHashIsStableSHA256Hex(t *testing.T) {
	require.Equal(t,
		"5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8",
		apiKeyCredentialHash("password"),
	)
}

func TestIsMissingAPIKeyHashColumn(t *testing.T) {
	require.True(t, isMissingAPIKeyHashColumn(errors.New(`no such column: key_hash`)))
	require.True(t, isMissingAPIKeyHashColumn(errors.New(`column "key_hash" does not exist`)))
	require.False(t, isMissingAPIKeyHashColumn(errors.New(`connection refused`)))

	pqErr := &pq.Error{Code: "42703", Message: "undefined column"}
	require.True(t, isMissingAPIKeyHashColumn(pqErr))
}
