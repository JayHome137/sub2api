//go:build unit

package service

import (
	"bytes"
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestGatewayServiceStickyLogsDoNotContainIdentifiers(t *testing.T) {
	const (
		deviceID      = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
		sessionID     = "123e4567-e89b-12d3-a456-426614174000"
		invalidUserID = "private-invalid-metadata-marker"
		cacheableText = "private-cacheable-content-marker"
		fallbackText  = "private-message-fallback-marker"
	)

	var output bytes.Buffer
	previousLogger := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&output, &slog.HandlerOptions{Level: slog.LevelDebug})))
	t.Cleanup(func() { slog.SetDefault(previousLogger) })

	svc := &GatewayService{}
	metadata := FormatMetadataUserID(deviceID, "", sessionID, "2.1.77")
	metadataRequest := mustParseSessionHashRequest(t, anthropicSessionBody(nil, nil, metadata), nil)
	require.Equal(t, sessionID, svc.GenerateSessionHash(metadataRequest))

	require.Empty(t, svc.GenerateSessionHash(&ParsedRequest{MetadataUserID: invalidUserID}))

	cacheableRequest := mustParseSessionHashRequest(t, anthropicSessionBody(
		[]any{map[string]any{
			"type":          "text",
			"text":          cacheableText,
			"cache_control": map[string]any{"type": "ephemeral"},
		}},
		nil,
		"",
	), nil)
	cacheableHash := svc.GenerateSessionHash(cacheableRequest)
	require.NotEmpty(t, cacheableHash)

	fallbackRequest := mustParseSessionHashRequest(t, anthropicSessionBody(
		nil,
		[]any{msg("user", fallbackText)},
		"",
	), nil)
	fallbackHash := svc.GenerateSessionHash(fallbackRequest)
	require.NotEmpty(t, fallbackHash)

	logs := output.String()
	require.Contains(t, logs, "sticky.hash_source")
	for _, sensitive := range []string{
		deviceID,
		sessionID,
		metadata,
		invalidUserID,
		cacheableText,
		cacheableHash,
		fallbackText,
		fallbackHash,
	} {
		require.NotContains(t, logs, sensitive)
	}
}

func TestStickyServiceLogsDoNotUseIdentifyingFields(t *testing.T) {
	serviceSource, err := os.ReadFile("gateway_service.go")
	require.NoError(t, err)
	serviceText := string(serviceSource)
	require.NotContains(t, serviceText, `slog.Info("sticky.`)
	for _, forbidden := range []string{
		`"session_id", uid.SessionID`,
		`"device_id", uid.DeviceID`,
		`"metadata_user_id", parsed.MetadataUserID`,
		`"hash", hash`,
	} {
		if strings.Contains(serviceText, forbidden) {
			t.Fatalf("gateway_service.go must not log sticky-session identifiers: found %s", forbidden)
		}
	}

	schedulingSource, err := os.ReadFile("gateway_scheduling.go")
	require.NoError(t, err)
	schedulingText := string(schedulingSource)
	require.NotContains(t, schedulingText, `slog.Info("sticky.scheduler_entry"`)
	require.Contains(t, schedulingText, `"has_group", groupID != nil`)
	require.Contains(t, schedulingText, `"has_session_hash", sessionHash != ""`)
	require.Contains(t, schedulingText, `"has_sticky_account", stickyAccountID > 0`)
	require.NotContains(t, schedulingText, "set session account failed: session=%s")
	require.Equal(t, 4, strings.Count(schedulingText, "set session account failed: has_session=%t"))
}

func TestShortSessionHashRedactsEveryNonEmptyIdentifier(t *testing.T) {
	require.Empty(t, shortSessionHash(""))
	require.Equal(t, "[redacted]", shortSessionHash("short"))
	require.Equal(t, "[redacted]", shortSessionHash("123e4567-e89b-12d3-a456-426614174000"))
}
