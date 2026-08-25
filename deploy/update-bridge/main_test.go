package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const testAuthorization = "Bearer 1234567890abcdef"

type fakeHelper struct {
	mu    sync.Mutex
	calls [][]string
	err   error
}

func (f *fakeHelper) Run(_ context.Context, args ...string) (helperResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, append([]string(nil), args...))
	return helperResult{Message: "ok"}, f.err
}

func newTestServer(t *testing.T, helper *fakeHelper, hasUpdate bool) (*bridgeServer, func()) {
	t.Helper()
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != testAuthorization {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/version":
			_ = json.NewEncoder(w).Encode(map[string]string{"version": "0.1.182"})
		case "/check-updates":
			_ = json.NewEncoder(w).Encode(versionInfoResponse{
				Code:    0,
				Message: "success",
				Data: versionInfo{
					CurrentVersion: "0.1.182",
					LatestVersion:  "0.1.183",
					HasUpdate:      hasUpdate,
				},
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	server := newBridgeServer(config{adminBaseURL: admin.URL, helperPath: "/unused"}, helper)
	return server, admin.Close
}

func TestUpdateRejectsMissingVersionEnvelopeData(t *testing.T) {
	helper := &fakeHelper{}
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != testAuthorization {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/version":
			_ = json.NewEncoder(w).Encode(map[string]string{"version": "0.1.182"})
		case "/check-updates":
			// This is the shape that previously decoded to zero values and was
			// incorrectly reported as "already up to date".
			_ = json.NewEncoder(w).Encode(versionInfo{
				CurrentVersion: "0.1.182",
				LatestVersion:  "0.1.183",
				HasUpdate:      true,
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer admin.Close()
	server := newBridgeServer(config{adminBaseURL: admin.URL, helperPath: "/unused"}, helper)

	response := request(t, server, http.MethodPost, "/update", "", true)
	if response.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if len(helper.calls) != 0 {
		t.Fatalf("helper calls = %#v", helper.calls)
	}
}

func request(t *testing.T, server *bridgeServer, method, path, body string, authorized bool) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if authorized {
		req.Header.Set("Authorization", testAuthorization)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	server.routes().ServeHTTP(response, req)
	return response
}

func TestUpdatePreparesOfficialLatestVersion(t *testing.T) {
	helper := &fakeHelper{}
	server, closeAdmin := newTestServer(t, helper, true)
	defer closeAdmin()

	response := request(t, server, http.MethodPost, "/update", "", true)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if !reflect.DeepEqual(helper.calls, [][]string{{"backend-prepare", "v0.1.183"}}) {
		t.Fatalf("helper calls = %#v", helper.calls)
	}
	var result updateResult
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || !result.NeedRestart {
		t.Fatalf("response = %s, err = %v", response.Body.String(), err)
	}
}

func TestRollbackNormalizesVersion(t *testing.T) {
	helper := &fakeHelper{}
	server, closeAdmin := newTestServer(t, helper, true)
	defer closeAdmin()

	response := request(t, server, http.MethodPost, "/rollback", `{"version":"0.1.181"}`, true)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if !reflect.DeepEqual(helper.calls, [][]string{{"backend-prepare", "v0.1.181"}}) {
		t.Fatalf("helper calls = %#v", helper.calls)
	}
}

func TestRestartActivatesPreparedImage(t *testing.T) {
	helper := &fakeHelper{}
	server, closeAdmin := newTestServer(t, helper, true)
	defer closeAdmin()

	response := request(t, server, http.MethodPost, "/restart", "", true)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if !reflect.DeepEqual(helper.calls, [][]string{{"backend-activate"}}) {
		t.Fatalf("helper calls = %#v", helper.calls)
	}
}

func TestUnauthorizedRequestNeverRunsHelper(t *testing.T) {
	helper := &fakeHelper{}
	server, closeAdmin := newTestServer(t, helper, true)
	defer closeAdmin()

	response := request(t, server, http.MethodPost, "/restart", "", false)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d", response.Code)
	}
	if len(helper.calls) != 0 {
		t.Fatalf("helper calls = %#v", helper.calls)
	}
}

func TestNoUpdateReturnsConflict(t *testing.T) {
	helper := &fakeHelper{}
	server, closeAdmin := newTestServer(t, helper, false)
	defer closeAdmin()

	response := request(t, server, http.MethodPost, "/update", "", true)
	if response.Code != http.StatusConflict {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if len(helper.calls) != 0 {
		t.Fatalf("helper calls = %#v", helper.calls)
	}
}
