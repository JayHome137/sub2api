package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	defaultListenAddr = "127.0.0.1:8091"
	defaultRepository = "JayHome137/sub2api"
	defaultWorkflow   = "web-update.yml"
	defaultAdminURL   = "http://127.0.0.1:8080/api/v1/admin/system/version"
	defaultGitHubURL  = "https://api.github.com"
	maxResponseBytes  = 2 << 20
)

var (
	releasePattern       = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	repositoryPattern    = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
	workflowPattern      = regexp.MustCompile(`^[A-Za-z0-9_.-]+\.ya?ml$`)
	errAdminUnauthorized = errors.New("administrator authentication rejected")
)

type config struct {
	listenAddr string
	repository string
	workflow   string
	adminURL   string
	githubURL  string
	token      string
}

type bridgeServer struct {
	cfg        config
	adminHTTP  *http.Client
	githubHTTP *http.Client
	mu         sync.Mutex
	pending    map[string]time.Time
}

type upgradeStatus struct {
	ReleaseTag      string `json:"release_tag"`
	State           string `json:"state"`
	CanDispatch     bool   `json:"can_dispatch"`
	BackendRequired bool   `json:"backend_required"`
	IssueURL        string `json:"issue_url,omitempty"`
	RunURL          string `json:"run_url,omitempty"`
}

type dispatchRequest struct {
	ReleaseTag string `json:"release_tag"`
}

type githubIssue struct {
	Number  int    `json:"number"`
	Title   string `json:"title"`
	Body    string `json:"body"`
	HTMLURL string `json:"html_url"`
	Labels  []struct {
		Name string `json:"name"`
	} `json:"labels"`
	PullRequest json.RawMessage `json:"pull_request"`
}

type workflowRuns struct {
	Runs []struct {
		DisplayTitle string `json:"display_title"`
		Status       string `json:"status"`
		Conclusion   string `json:"conclusion"`
		HTMLURL      string `json:"html_url"`
		CreatedAt    string `json:"created_at"`
	} `json:"workflow_runs"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}

	server := newBridgeServer(cfg)
	httpServer := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           server.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      20 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("aifoo update bridge listening on %s", cfg.listenAddr)
	log.Fatal(httpServer.ListenAndServe())
}

func loadConfig() (config, error) {
	tokenFile := envOr("AIFOO_UPGRADE_GITHUB_TOKEN_FILE", "/etc/aifoo-update-bridge/github-token")
	tokenBytes, err := os.ReadFile(tokenFile)
	if err != nil {
		return config{}, fmt.Errorf("read GitHub token file: %w", err)
	}
	token := strings.TrimSpace(string(tokenBytes))
	if token == "" {
		return config{}, errors.New("GitHub token file is empty")
	}

	cfg := config{
		listenAddr: envOr("AIFOO_UPGRADE_LISTEN_ADDR", defaultListenAddr),
		repository: envOr("AIFOO_UPGRADE_GITHUB_REPOSITORY", defaultRepository),
		workflow:   envOr("AIFOO_UPGRADE_GITHUB_WORKFLOW", defaultWorkflow),
		adminURL:   envOr("AIFOO_UPGRADE_ADMIN_CHECK_URL", defaultAdminURL),
		githubURL:  strings.TrimRight(envOr("AIFOO_UPGRADE_GITHUB_API", defaultGitHubURL), "/"),
		token:      token,
	}
	if !repositoryPattern.MatchString(cfg.repository) {
		return config{}, errors.New("invalid GitHub repository")
	}
	if !workflowPattern.MatchString(cfg.workflow) {
		return config{}, errors.New("invalid GitHub workflow name")
	}
	if _, err := url.ParseRequestURI(cfg.adminURL); err != nil {
		return config{}, fmt.Errorf("invalid admin check URL: %w", err)
	}
	if _, err := url.ParseRequestURI(cfg.githubURL); err != nil {
		return config{}, fmt.Errorf("invalid GitHub API URL: %w", err)
	}
	return cfg, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func newBridgeServer(cfg config) *bridgeServer {
	return &bridgeServer{
		cfg:        cfg,
		adminHTTP:  &http.Client{Timeout: 8 * time.Second},
		githubHTTP: &http.Client{Timeout: 15 * time.Second},
		pending:    make(map[string]time.Time),
	}
}

func (s *bridgeServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/status", s.withAdmin(s.handleStatus))
	mux.HandleFunc("/dispatch", s.withAdmin(s.handleDispatch))
	return mux
}

func (s *bridgeServer) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *bridgeServer) withAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := s.verifyAdmin(r); err != nil {
			if errors.Is(err, errAdminUnauthorized) {
				writeError(w, http.StatusUnauthorized, "administrator authentication required")
			} else {
				log.Printf("administrator verification failed: %v", err)
				writeError(w, http.StatusBadGateway, "administrator verification unavailable")
			}
			return
		}
		next(w, r)
	}
}

func (s *bridgeServer) verifyAdmin(r *http.Request) error {
	authorization := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(authorization, "Bearer ") || len(strings.TrimSpace(strings.TrimPrefix(authorization, "Bearer "))) < 16 {
		return errAdminUnauthorized
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, s.cfg.adminURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", authorization)
	resp, err := s.adminHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return errAdminUnauthorized
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("admin check returned %d", resp.StatusCode)
	}
	return nil
}

func (s *bridgeServer) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	tag := strings.TrimSpace(r.URL.Query().Get("release"))
	if !releasePattern.MatchString(tag) {
		writeError(w, http.StatusBadRequest, "release must be vX.Y.Z")
		return
	}
	status, err := s.readStatus(r.Context(), tag)
	if err != nil {
		log.Printf("read upgrade status failed: %v", err)
		writeError(w, http.StatusBadGateway, "upgrade status unavailable")
		return
	}
	writeJSON(w, http.StatusOK, status)
}

func (s *bridgeServer) handleDispatch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	defer r.Body.Close()
	decoder := json.NewDecoder(io.LimitReader(r.Body, 4096))
	decoder.DisallowUnknownFields()
	var input dispatchRequest
	if err := decoder.Decode(&input); err != nil || !releasePattern.MatchString(input.ReleaseTag) {
		writeError(w, http.StatusBadRequest, "release_tag must be vX.Y.Z")
		return
	}

	status, err := s.readStatus(r.Context(), input.ReleaseTag)
	if err != nil {
		log.Printf("pre-dispatch status failed: %v", err)
		writeError(w, http.StatusBadGateway, "upgrade status unavailable")
		return
	}
	if status.State == "deploying" {
		writeJSON(w, http.StatusOK, status)
		return
	}
	if !status.CanDispatch {
		writeError(w, http.StatusConflict, "release is not ready for deployment")
		return
	}
	if !s.claimDispatch(input.ReleaseTag) {
		status.State = "deploying"
		status.CanDispatch = false
		writeJSON(w, http.StatusOK, status)
		return
	}

	payload, _ := json.Marshal(map[string]any{
		"ref": "production",
		"inputs": map[string]string{
			"release_tag": input.ReleaseTag,
		},
	})
	path := fmt.Sprintf("/repos/%s/actions/workflows/%s/dispatches", s.cfg.repository, s.cfg.workflow)
	if err := s.githubRequest(r.Context(), http.MethodPost, path, bytes.NewReader(payload), nil); err != nil {
		s.clearPending(input.ReleaseTag)
		log.Printf("dispatch upgrade workflow failed: %v", err)
		writeError(w, http.StatusBadGateway, "unable to start deployment")
		return
	}
	status.State = "deploying"
	status.CanDispatch = false
	writeJSON(w, http.StatusAccepted, status)
}

func (s *bridgeServer) claimDispatch(tag string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if started, ok := s.pending[tag]; ok && time.Since(started) <= 2*time.Minute {
		return false
	}
	s.pending[tag] = time.Now()
	return true
}

func (s *bridgeServer) clearPending(tag string) {
	s.mu.Lock()
	delete(s.pending, tag)
	s.mu.Unlock()
}

func (s *bridgeServer) readStatus(ctx context.Context, tag string) (upgradeStatus, error) {
	result := upgradeStatus{ReleaseTag: tag, State: "preparing"}
	issue, err := s.findIssue(ctx, tag)
	if err != nil {
		return result, err
	}
	if issue == nil {
		if s.isPending(tag) {
			result.State = "deploying"
		}
		return result, nil
	}
	result.IssueURL = issue.HTMLURL
	labels := make(map[string]bool, len(issue.Labels))
	for _, label := range issue.Labels {
		labels[label.Name] = true
	}
	result.BackendRequired = labels["backend-deploy-required"] && !labels["backend-deployed"]

	run, err := s.latestRun(ctx, tag)
	if err != nil {
		return result, err
	}
	if run != nil {
		result.RunURL = run.HTMLURL
		if run.Status == "queued" || run.Status == "in_progress" || run.Status == "waiting" {
			result.State = "deploying"
			return result, nil
		}
		if run.Status == "completed" && run.Conclusion == "success" {
			result.State = "deployed"
			return result, nil
		}
	}
	if s.isPending(tag) {
		result.State = "deploying"
		return result, nil
	}
	if labels["vps-deployed"] {
		result.State = "deployed"
		return result, nil
	}
	if labels["ui-review-required"] {
		result.State = "ui_review_required"
		return result, nil
	}
	if labels["sync-failed"] {
		result.State = "failed"
		return result, nil
	}
	if labels["ready-for-vps"] {
		result.State = "ready"
		result.CanDispatch = true
		if run != nil && run.Status == "completed" && run.Conclusion != "success" {
			result.State = "failed"
		}
	}
	return result, nil
}

func (s *bridgeServer) isPending(tag string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	started, ok := s.pending[tag]
	if !ok {
		return false
	}
	if time.Since(started) > 2*time.Minute {
		delete(s.pending, tag)
		return false
	}
	return true
}

func (s *bridgeServer) findIssue(ctx context.Context, tag string) (*githubIssue, error) {
	query := url.Values{
		"state":     {"all"},
		"labels":    {"upstream-release"},
		"sort":      {"created"},
		"direction": {"desc"},
		"per_page":  {"100"},
	}
	path := fmt.Sprintf("/repos/%s/issues?%s", s.cfg.repository, query.Encode())
	var issues []githubIssue
	if err := s.githubRequest(ctx, http.MethodGet, path, nil, &issues); err != nil {
		return nil, err
	}
	title := fmt.Sprintf("[Upstream %s] AIFoo frontend compatibility", tag)
	for i := range issues {
		if len(issues[i].PullRequest) == 0 && issues[i].Title == title {
			return &issues[i], nil
		}
	}
	return nil, nil
}

func (s *bridgeServer) latestRun(ctx context.Context, tag string) (*struct {
	DisplayTitle string `json:"display_title"`
	Status       string `json:"status"`
	Conclusion   string `json:"conclusion"`
	HTMLURL      string `json:"html_url"`
	CreatedAt    string `json:"created_at"`
}, error) {
	query := url.Values{
		"branch":   {"production"},
		"event":    {"workflow_dispatch"},
		"per_page": {"30"},
	}
	path := fmt.Sprintf("/repos/%s/actions/workflows/%s/runs?%s", s.cfg.repository, s.cfg.workflow, query.Encode())
	var runs workflowRuns
	if err := s.githubRequest(ctx, http.MethodGet, path, nil, &runs); err != nil {
		return nil, err
	}
	title := "AIFoo web update " + tag
	for i := range runs.Runs {
		if runs.Runs[i].DisplayTitle == title {
			return &runs.Runs[i], nil
		}
	}
	return nil, nil
}

func (s *bridgeServer) githubRequest(ctx context.Context, method, path string, body io.Reader, target any) error {
	req, err := http.NewRequestWithContext(ctx, method, s.cfg.githubURL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Authorization", "Bearer "+s.cfg.token)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := s.githubHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	limited := io.LimitReader(resp.Body, maxResponseBytes)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, limited)
		return fmt.Errorf("GitHub API %s %s returned %d", method, path, resp.StatusCode)
	}
	if target == nil || resp.StatusCode == http.StatusNoContent {
		_, _ = io.Copy(io.Discard, limited)
		return nil
	}
	return json.NewDecoder(limited).Decode(target)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"message": message})
}
