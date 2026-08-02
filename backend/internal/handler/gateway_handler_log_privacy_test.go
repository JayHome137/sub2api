package handler

import (
	"os"
	"strings"
	"testing"
)

func TestGatewayHandlerDoesNotLogRawStickySessionIdentifiers(t *testing.T) {
	source, err := os.ReadFile("gateway_handler.go")
	if err != nil {
		t.Fatalf("read gateway_handler.go: %v", err)
	}

	for _, forbidden := range []string{
		`zap.String("session_hash",`,
		`zap.String("session_key",`,
		`zap.String("metadata_user_id_raw",`,
	} {
		if strings.Contains(string(source), forbidden) {
			t.Fatalf("gateway handler must not log raw sticky-session identifiers: found %s", forbidden)
		}
	}
}
