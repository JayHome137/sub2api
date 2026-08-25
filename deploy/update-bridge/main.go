package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	defaultListenAddr   = "127.0.0.1:8091"
	defaultAdminBaseURL = "http://127.0.0.1:8080/api/v1/admin/system"
	defaultHelperPath   = "/usr/local/libexec/aifoo-deploy-helper"
	maxResponseBytes    = 1 << 20
	operationTimeout    = 15 * time.Minute
)

var (
	versionPattern       = regexp.MustCompile(`^v?[0-9]+\.[0-9]+\.[0-9]+$`)
	errAdminUnauthorized = errors.New("administrator authentication rejected")
)

type config struct {
	listenAddr   string
	adminBaseURL string
	helperPath   string
}

type helperResult struct {
	Message       string `json:"message"`
	TargetVersion string `json:"target_version,omitempty"`
}

type helperRunner interface {
	Run(context.Context, ...string) (helperResult, error)
}

type commandRunner struct {
	path string
}

func (r commandRunner) Run(ctx context.Context, args ...string) (helperResult, error) {
	cmd := exec.CommandContext(ctx, r.path, args...)
	output, err := cmd.CombinedOutput()
	if len(output) > 16*1024 {
		output = output[:16*1024]
	}
	if err != nil {
		return helperResult{}, fmt.Errorf("helper failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	var result helperResult
	if err := json.Unmarshal(output, &result); err != nil {
		return helperResult{}, fmt.Errorf("decode helper response: %w", err)
	}
	if strings.TrimSpace(result.Message) == "" {
		return helperResult{}, errors.New("helper returned an empty message")
	}
	return result, nil
}

type bridgeServer struct {
	cfg       config
	adminHTTP *http.Client
	helper    helperRunner
}

type versionInfo struct {
	CurrentVersion string `json:"current_version"`
	LatestVersion  string `json:"latest_version"`
	HasUpdate      bool   `json:"has_update"`
}

type versionInfoResponse struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    versionInfo `json:"data"`
}

type rollbackRequest struct {
	Version string `json:"version"`
}

type updateResult struct {
	Message     string `json:"message"`
	NeedRestart bool   `json:"need_restart"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}
	server := newBridgeServer(cfg, commandRunner{path: cfg.helperPath})
	httpServer := &http.Server{
		Addr:              cfg.listenAddr,
		Handler:           server.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      operationTimeout + time.Minute,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("aifoo update bridge listening on %s", cfg.listenAddr)
	log.Fatal(httpServer.ListenAndServe())
}

func loadConfig() (config, error) {
	cfg := config{
		listenAddr:   envOr("AIFOO_UPGRADE_LISTEN_ADDR", defaultListenAddr),
		adminBaseURL: strings.TrimRight(envOr("AIFOO_UPGRADE_ADMIN_BASE_URL", defaultAdminBaseURL), "/"),
		helperPath:   envOr("AIFOO_UPGRADE_HELPER", defaultHelperPath),
	}
	parsed, err := url.ParseRequestURI(cfg.adminBaseURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || !isLoopback(parsed.Hostname()) {
		return config{}, errors.New("administrator API must be an HTTP URL on loopback")
	}
	if !filepath.IsAbs(cfg.helperPath) || filepath.Clean(cfg.helperPath) != cfg.helperPath {
		return config{}, errors.New("helper path must be an absolute clean path")
	}
	return cfg, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func newBridgeServer(cfg config, helper helperRunner) *bridgeServer {
	return &bridgeServer{
		cfg:       cfg,
		adminHTTP: &http.Client{Timeout: 10 * time.Second},
		helper:    helper,
	}
}

func (s *bridgeServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/update", s.withAdmin(s.handleUpdate))
	mux.HandleFunc("/rollback", s.withAdmin(s.handleRollback))
	mux.HandleFunc("/restart", s.withAdmin(s.handleRestart))
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
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, s.cfg.adminBaseURL+"/version", nil)
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

func (s *bridgeServer) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	info, err := s.checkUpdates(r)
	if err != nil {
		log.Printf("official update check failed: %v", err)
		writeError(w, http.StatusBadGateway, "official update check unavailable")
		return
	}
	if !info.HasUpdate {
		writeError(w, http.StatusConflict, "the official backend is already up to date")
		return
	}
	target, err := normalizeVersion(info.LatestVersion)
	if err != nil {
		writeError(w, http.StatusBadGateway, "official update check returned an invalid version")
		return
	}
	s.runPreparation(w, r, target)
}

func (s *bridgeServer) checkUpdates(r *http.Request) (versionInfo, error) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, s.cfg.adminBaseURL+"/check-updates?force=true", nil)
	if err != nil {
		return versionInfo{}, err
	}
	req.Header.Set("Authorization", r.Header.Get("Authorization"))
	resp, err := s.adminHTTP.Do(req)
	if err != nil {
		return versionInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return versionInfo{}, fmt.Errorf("update check returned %d", resp.StatusCode)
	}
	var payload versionInfoResponse
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxResponseBytes)).Decode(&payload); err != nil {
		return versionInfo{}, err
	}
	if payload.Code != 0 {
		return versionInfo{}, fmt.Errorf("update check returned API code %d", payload.Code)
	}
	if strings.TrimSpace(payload.Data.CurrentVersion) == "" || strings.TrimSpace(payload.Data.LatestVersion) == "" {
		return versionInfo{}, errors.New("update check returned incomplete version data")
	}
	return payload.Data, nil
}

func (s *bridgeServer) handleRollback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	defer r.Body.Close()
	var input rollbackRequest
	decoder := json.NewDecoder(io.LimitReader(r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "rollback version is required")
		return
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "rollback request must contain one JSON object")
		return
	}
	target, err := normalizeVersion(input.Version)
	if err != nil {
		writeError(w, http.StatusBadRequest, "rollback version must be X.Y.Z")
		return
	}
	s.runPreparation(w, r, target)
}

func (s *bridgeServer) runPreparation(w http.ResponseWriter, r *http.Request, target string) {
	ctx, cancel := context.WithTimeout(r.Context(), operationTimeout)
	defer cancel()
	result, err := s.helper.Run(ctx, "backend-prepare", target)
	if err != nil {
		log.Printf("backend preparation failed: %v", err)
		writeError(w, http.StatusBadGateway, "unable to prepare the official backend image")
		return
	}
	writeJSON(w, http.StatusOK, updateResult{Message: result.Message, NeedRestart: true})
}

func (s *bridgeServer) handleRestart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), operationTimeout)
	defer cancel()
	result, err := s.helper.Run(ctx, "backend-activate")
	if err != nil {
		log.Printf("backend activation failed: %v", err)
		writeError(w, http.StatusBadGateway, "backend activation failed; the previous image remains active or was restored")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"message": result.Message})
}

func normalizeVersion(value string) (string, error) {
	value = strings.TrimSpace(value)
	if !versionPattern.MatchString(value) {
		return "", errors.New("invalid version")
	}
	if value[0] != 'v' {
		value = "v" + value
	}
	return value, nil
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
