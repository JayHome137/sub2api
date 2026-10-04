//go:build unit

package service

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestBuildAntigravityClientErrorBodyScrubsPoolIdentity(t *testing.T) {
	upstream := []byte(`{"error":{"code":403,"message":"Permission denied on resource project projects/123456789 for consumer: projects/123456789; caller pool-sa@my-gcp-proj.iam.gserviceaccount.com","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","metadata":{"consumer":"projects/123456789"}}]}}`)

	out := buildAntigravityClientErrorBody(http.StatusForbidden, upstream)
	require.NotContains(t, string(out), "123456789")
	require.NotContains(t, string(out), "pool-sa@")
	require.NotContains(t, string(out), "gserviceaccount.com")
	require.NotContains(t, string(out), "details")

	var parsed struct {
		Error struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
			Status  string `json:"status"`
		} `json:"error"`
	}
	require.NoError(t, json.Unmarshal(out, &parsed))
	require.Equal(t, 403, parsed.Error.Code)
	require.Equal(t, "PERMISSION_DENIED", parsed.Error.Status)
	require.Contains(t, parsed.Error.Message, "Permission denied")
}

func TestBuildAntigravityClientErrorBodyNonJSONBody(t *testing.T) {
	out := string(buildAntigravityClientErrorBody(http.StatusTooManyRequests, []byte("quota exceeded for consumer 987654321 sa@x.iam.gserviceaccount.com")))
	require.NotContains(t, out, "987654321")
	require.NotContains(t, out, "gserviceaccount")
	require.Contains(t, out, `"status":"RESOURCE_EXHAUSTED"`)
	require.Contains(t, out, `"code":429`)
}
