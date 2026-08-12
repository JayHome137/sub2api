package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type fakeGitHubState struct {
	labels       []string
	runs         []map[string]string
	dispatches   atomic.Int32
	dispatchBody []byte
	dispatchAuth string
	adminStatus  int
	adminAuth    string
}

func newTestBridge(t *testing.T, state *fakeGitHubState) (*bridgeServer, *httptest.Server) {
	t.Helper()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/admin":
			state.adminAuth = r.Header.Get("Authorization")
			status := state.adminStatus
			if status == 0 {
				status = http.StatusOK
			}
			w.WriteHeader(status)
		case strings.HasSuffix(r.URL.Path, "/issues"):
			labels := make([]map[string]string, 0, len(state.labels))
			for _, label := range state.labels {
				labels = append(labels, map[string]string{"name": label})
			}
			_ = json.NewEncoder(w).Encode([]map[string]any{{
				"number":   17,
				"title":    "[Upstream v0.1.172] AIFoo frontend compatibility",
				"body":     "candidate",
				"html_url": "https://github.example/issues/17",
				"labels":   labels,
			}})
		case strings.HasSuffix(r.URL.Path, "/runs"):
			_ = json.NewEncoder(w).Encode(map[string]any{"workflow_runs": state.runs})
		case strings.HasSuffix(r.URL.Path, "/dispatches"):
			state.dispatches.Add(1)
			state.dispatchAuth = r.Header.Get("Authorization")
			state.dispatchBody, _ = io.ReadAll(r.Body)
			w.WriteHeader(http.StatusNoContent)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(upstream.Close)

	server := newBridgeServer(config{
		repository: "JayHome137/sub2api",
		workflow:   "web-update.yml",
		adminURL:   upstream.URL + "/admin",
		githubURL:  upstream.URL,
		token:      "github-secret",
	})
	return server, httptest.NewServer(server.routes())
}

func request(t *testing.T, client *http.Client, method, target, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, target, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer admin-token-long-enough")
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func decodeStatus(t *testing.T, resp *http.Response) upgradeStatus {
	t.Helper()
	defer resp.Body.Close()
	var status upgradeStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		t.Fatal(err)
	}
	return status
}

func TestStatusRejectsNonAdministrator(t *testing.T) {
	state := &fakeGitHubState{adminStatus: http.StatusUnauthorized}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusUnauthorized)
	}
	if state.dispatches.Load() != 0 {
		t.Fatal("unauthenticated request reached GitHub dispatch")
	}
}

func TestStatusReportsAdminVerificationOutageWithoutLoggingUserOut(t *testing.T) {
	state := &fakeGitHubState{adminStatus: http.StatusServiceUnavailable}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusBadGateway)
	}
	if state.dispatches.Load() != 0 {
		t.Fatal("verification outage reached GitHub dispatch")
	}
}

func TestReadyStatus(t *testing.T) {
	state := &fakeGitHubState{labels: []string{
		"upstream-release", "ready-for-vps", "vps-preloaded",
		"backend-deploy-required", "backend-prepared",
	}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if resp.StatusCode != http.StatusOK || status.State != "ready" || !status.CanDispatch || !status.BackendRequired {
		t.Fatalf("unexpected status: code=%d body=%+v", resp.StatusCode, status)
	}
	if state.adminAuth != "Bearer admin-token-long-enough" {
		t.Fatalf("admin authorization was not forwarded: %q", state.adminAuth)
	}
}

func TestUIReviewBlocksDispatch(t *testing.T) {
	state := &fakeGitHubState{labels: []string{"upstream-release", "ready-for-vps", "vps-preloaded", "ui-review-required"}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodPost, bridge.URL+"/dispatch", `{"release_tag":"v0.1.172"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("status = %d, want %d", resp.StatusCode, http.StatusConflict)
	}
	if state.dispatches.Load() != 0 {
		t.Fatal("UI review gate was bypassed")
	}
}

func TestDispatchIsFixedAndIdempotent(t *testing.T) {
	state := &fakeGitHubState{labels: []string{"upstream-release", "ready-for-vps", "vps-preloaded"}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	for _, expectedCode := range []int{http.StatusAccepted, http.StatusOK} {
		resp := request(t, bridge.Client(), http.MethodPost, bridge.URL+"/dispatch", `{"release_tag":"v0.1.172"}`)
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != expectedCode {
			t.Fatalf("status = %d, want %d: %s", resp.StatusCode, expectedCode, body)
		}
		if strings.Contains(string(body), "github-secret") {
			t.Fatal("GitHub token leaked into the browser response")
		}
	}
	if state.dispatches.Load() != 1 {
		t.Fatalf("dispatch count = %d, want 1", state.dispatches.Load())
	}
	if state.dispatchAuth != "Bearer github-secret" {
		t.Fatalf("GitHub authorization = %q", state.dispatchAuth)
	}
	var payload map[string]any
	if err := json.Unmarshal(state.dispatchBody, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["ref"] != "production" {
		t.Fatalf("dispatch ref = %v", payload["ref"])
	}
	inputs, ok := payload["inputs"].(map[string]any)
	if !ok || inputs["release_tag"] != "v0.1.172" {
		t.Fatalf("dispatch inputs = %#v", payload["inputs"])
	}
}

func TestSuccessfulWorkflowIsDeployed(t *testing.T) {
	state := &fakeGitHubState{
		labels: []string{"upstream-release", "vps-deployed"},
		runs: []map[string]string{{
			"display_title": "AIFoo web update v0.1.172",
			"status":        "completed",
			"conclusion":    "success",
			"html_url":      "https://github.example/actions/runs/42",
		}},
	}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if status.State != "deployed" || status.CanDispatch {
		t.Fatalf("unexpected status: %+v", status)
	}
	if status.RunURL != "https://github.example/actions/runs/42" {
		t.Fatalf("run URL = %q", status.RunURL)
	}
}

func TestOldSuccessfulRunDoesNotHideNewReadyRelease(t *testing.T) {
	state := &fakeGitHubState{
		labels: []string{"upstream-release", "ready-for-vps", "vps-preloaded"},
		runs: []map[string]string{{
			"display_title": "AIFoo web update v0.1.172",
			"status":        "completed",
			"conclusion":    "success",
		}},
	}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if status.State != "ready" || !status.CanDispatch {
		t.Fatalf("old successful run hid a newly prepared candidate: %+v", status)
	}
}

func TestFailedActivationRemainsRetryableAfterPreparation(t *testing.T) {
	state := &fakeGitHubState{
		labels: []string{
			"upstream-release", "ready-for-vps", "vps-preloaded", "web-update-failed",
		},
		runs: []map[string]string{{
			"display_title": "AIFoo web update v0.1.172",
			"status":        "completed",
			"conclusion":    "failure",
		}},
	}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if status.State != "failed" || !status.CanDispatch {
		t.Fatalf("prepared failed activation is not retryable: %+v", status)
	}
}

func TestReadyStatusWaitsForVPSPreload(t *testing.T) {
	state := &fakeGitHubState{labels: []string{"upstream-release", "ready-for-vps"}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if status.State != "preparing" || status.CanDispatch {
		t.Fatalf("unpreloaded candidate became clickable: %+v", status)
	}
}

func TestBackendReleaseWaitsForPreparedState(t *testing.T) {
	state := &fakeGitHubState{labels: []string{
		"upstream-release", "ready-for-vps", "vps-preloaded", "backend-deploy-required",
	}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if status.State != "preparing" || status.CanDispatch || !status.BackendRequired {
		t.Fatalf("unprepared backend candidate became clickable: %+v", status)
	}
}

func TestPreparedBackendReleaseIsReady(t *testing.T) {
	state := &fakeGitHubState{labels: []string{
		"upstream-release", "ready-for-vps", "vps-preloaded",
		"backend-deploy-required", "backend-prepared",
	}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodGet, bridge.URL+"/status?release=v0.1.172", "")
	status := decodeStatus(t, resp)
	if status.State != "ready" || !status.CanDispatch || !status.BackendRequired {
		t.Fatalf("prepared backend candidate is not clickable: %+v", status)
	}
}

func TestBackendPreparationFailureBlocksDispatch(t *testing.T) {
	state := &fakeGitHubState{labels: []string{
		"upstream-release", "ready-for-vps", "vps-preloaded",
		"backend-deploy-required", "backend-prepare-failed",
	}}
	_, bridge := newTestBridge(t, state)
	defer bridge.Close()

	resp := request(t, bridge.Client(), http.MethodPost, bridge.URL+"/dispatch", `{"release_tag":"v0.1.172"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict || state.dispatches.Load() != 0 {
		t.Fatalf("failed backend preparation reached dispatch: code=%d dispatches=%d", resp.StatusCode, state.dispatches.Load())
	}
}
