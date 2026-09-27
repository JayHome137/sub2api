package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	backendRepository  = "weishaw/sub2api"
	frontendRepository = "ghcr.io/jayhome137/sub2api-frontend"
)

var (
	versionPattern       = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
	digestPattern        = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	usernamePattern      = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)
	binaryVersionPattern = regexp.MustCompile(`(?m)Sub2API\s+v?([0-9]+\.[0-9]+\.[0-9]+)\b`)
)

type configuration struct {
	composeFile       string
	stateDir          string
	lockFile          string
	backendService    string
	backendContainer  string
	frontendService   string
	frontendContainer string
	healthTimeout     time.Duration
}

type preparedState struct {
	TargetVersion   string    `json:"target_version"`
	TargetImage     string    `json:"target_image"`
	PreviousVersion string    `json:"previous_version"`
	PreviousImage   string    `json:"previous_image"`
	PreparedAt      time.Time `json:"prepared_at"`
}

type commandResult struct {
	Message       string `json:"message"`
	TargetVersion string `json:"target_version,omitempty"`
	Image         string `json:"image,omitempty"`
}

type executor interface {
	Run(context.Context, string, []string, io.Reader) ([]byte, error)
}

type osExecutor struct{}

func (osExecutor) Run(ctx context.Context, name string, args []string, stdin io.Reader) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = stdin
	var output cappedBuffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	err := cmd.Run()
	if err != nil {
		return output.Bytes(), fmt.Errorf("%s failed: %w", filepath.Base(name), err)
	}
	return output.Bytes(), nil
}

type cappedBuffer struct {
	data []byte
}

func (b *cappedBuffer) Write(value []byte) (int, error) {
	const limit = 32 * 1024
	remaining := limit - len(b.data)
	if remaining > 0 {
		if len(value) < remaining {
			remaining = len(value)
		}
		b.data = append(b.data, value[:remaining]...)
	}
	return len(value), nil
}

func (b *cappedBuffer) Bytes() []byte {
	return b.data
}

type app struct {
	cfg     configuration
	exec    executor
	docker  string
	compose []string
}

func main() {
	if os.Geteuid() != 0 {
		fatal(errors.New("aifoo-deploy-helper must run as root"))
	}
	cfg, err := loadConfiguration()
	if err != nil {
		fatal(err)
	}
	lock, err := acquireLock(cfg.lockFile)
	if err != nil {
		fatal(err)
	}
	defer lock.Close()

	application, err := newApp(cfg, osExecutor{})
	if err != nil {
		fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 14*time.Minute)
	defer cancel()
	result, err := application.run(ctx, os.Args[1:])
	if err != nil {
		fatal(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func loadConfiguration() (configuration, error) {
	healthTimeout := 3 * time.Minute
	if raw := strings.TrimSpace(os.Getenv("AIFOO_HEALTH_TIMEOUT")); raw != "" {
		parsed, err := time.ParseDuration(raw)
		if err != nil || parsed < 10*time.Second || parsed > 10*time.Minute {
			return configuration{}, errors.New("AIFOO_HEALTH_TIMEOUT must be between 10s and 10m")
		}
		healthTimeout = parsed
	}
	appDir := envOr("AIFOO_APP_DIR", "/opt/sub2api")
	stateDir := envOr("AIFOO_STATE_DIR", "/var/lib/aifoo-deploy-helper")
	return configuration{
		composeFile:       envOr("AIFOO_COMPOSE_FILE", filepath.Join(appDir, "docker-compose.yml")),
		stateDir:          stateDir,
		lockFile:          envOr("AIFOO_LOCK_FILE", "/run/lock/aifoo-deploy-helper.lock"),
		backendService:    envOr("AIFOO_BACKEND_SERVICE", "sub2api"),
		backendContainer:  envOr("AIFOO_BACKEND_CONTAINER", "sub2api"),
		frontendService:   envOr("AIFOO_FRONTEND_SERVICE", "frontend"),
		frontendContainer: envOr("AIFOO_FRONTEND_CONTAINER", "sub2api-frontend"),
		healthTimeout:     healthTimeout,
	}, nil
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func acquireLock(path string) (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return nil, errors.New("another deployment operation is already running")
	}
	return file, nil
}

func newApp(cfg configuration, runner executor) (*app, error) {
	docker, err := exec.LookPath("docker")
	if err != nil {
		return nil, errors.New("docker is not installed")
	}
	compose, err := detectCompose()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(cfg.stateDir, 0700); err != nil {
		return nil, err
	}
	return &app{cfg: cfg, exec: runner, docker: docker, compose: compose}, nil
}

func detectCompose() ([]string, error) {
	if configured := strings.TrimSpace(os.Getenv("AIFOO_COMPOSE_BIN")); configured != "" {
		if !filepath.IsAbs(configured) {
			return nil, errors.New("AIFOO_COMPOSE_BIN must be an absolute path")
		}
		return []string{configured}, nil
	}
	if path, err := exec.LookPath("docker-compose"); err == nil {
		return []string{path}, nil
	}
	if path, err := exec.LookPath("docker"); err == nil {
		return []string{path, "compose"}, nil
	}
	return nil, errors.New("Docker Compose is not installed")
}

func (a *app) run(ctx context.Context, args []string) (commandResult, error) {
	if len(args) == 0 {
		return commandResult{}, errors.New("expected backend-prepare, backend-activate, frontend-login, frontend-activate, or frontend-logout")
	}
	switch args[0] {
	case "backend-prepare":
		if len(args) != 2 {
			return commandResult{}, errors.New("backend-prepare requires vX.Y.Z")
		}
		return a.prepareBackend(ctx, args[1])
	case "backend-activate":
		if len(args) != 1 {
			return commandResult{}, errors.New("backend-activate accepts no arguments")
		}
		return a.activateBackend(ctx)
	case "frontend-login":
		if len(args) != 2 || !usernamePattern.MatchString(args[1]) {
			return commandResult{}, errors.New("frontend-login requires a valid registry username")
		}
		return a.frontendLogin(ctx, args[1])
	case "frontend-activate":
		if len(args) != 2 {
			return commandResult{}, errors.New("frontend-activate requires an immutable image digest")
		}
		return a.activateFrontend(ctx, args[1])
	case "frontend-logout":
		if len(args) != 1 {
			return commandResult{}, errors.New("frontend-logout accepts no arguments")
		}
		return a.frontendLogout(ctx)
	default:
		return commandResult{}, errors.New("unsupported deployment operation")
	}
}

func (a *app) prepareBackend(ctx context.Context, version string) (commandResult, error) {
	if !versionPattern.MatchString(version) {
		return commandResult{}, errors.New("backend version must be vX.Y.Z")
	}
	currentImage, _, err := readComposeImage(a.cfg.composeFile, a.cfg.backendService)
	if err != nil {
		return commandResult{}, err
	}
	if !isRepositoryReference(currentImage, backendRepository) {
		return commandResult{}, fmt.Errorf("backend service is not using %s", backendRepository)
	}
	currentVersion, err := a.containerVersion(ctx, a.cfg.backendContainer)
	if err != nil {
		return commandResult{}, fmt.Errorf("read active backend version: %w", err)
	}
	if currentVersion == version {
		return commandResult{}, fmt.Errorf("backend %s is already active", version)
	}

	taggedImage := backendRepository + ":" + strings.TrimPrefix(version, "v")
	if _, err := a.runDocker(ctx, nil, "pull", taggedImage); err != nil {
		return commandResult{}, err
	}
	digestImage, err := a.resolveDigest(ctx, taggedImage, backendRepository)
	if err != nil {
		return commandResult{}, err
	}
	imageVersion, err := a.imageVersion(ctx, digestImage)
	if err != nil {
		return commandResult{}, err
	}
	if imageVersion != version {
		return commandResult{}, fmt.Errorf("official image reports %s, expected %s", imageVersion, version)
	}

	state := preparedState{
		TargetVersion:   version,
		TargetImage:     digestImage,
		PreviousVersion: currentVersion,
		PreviousImage:   currentImage,
		PreparedAt:      time.Now().UTC(),
	}
	if err := writeJSONAtomic(a.preparedPath(), state); err != nil {
		return commandResult{}, err
	}
	return commandResult{
		Message:       fmt.Sprintf("Official backend %s is ready. Restart to activate it.", version),
		TargetVersion: version,
		Image:         digestImage,
	}, nil
}

func (a *app) activateBackend(ctx context.Context) (commandResult, error) {
	var state preparedState
	if err := readJSON(a.preparedPath(), &state); err != nil {
		return commandResult{}, fmt.Errorf("read prepared backend state: %w", err)
	}
	if !versionPattern.MatchString(state.TargetVersion) || !isDigestReference(state.TargetImage, backendRepository) {
		return commandResult{}, errors.New("prepared backend state is invalid")
	}
	currentImage, original, err := readComposeImage(a.cfg.composeFile, a.cfg.backendService)
	if err != nil {
		return commandResult{}, err
	}
	if currentImage != state.PreviousImage && currentImage != state.TargetImage {
		return commandResult{}, errors.New("Compose backend image changed after preparation; prepare again")
	}
	if currentImage == state.PreviousImage {
		currentVersion, err := a.containerVersion(ctx, a.cfg.backendContainer)
		if err != nil || currentVersion != state.PreviousVersion {
			return commandResult{}, errors.New("active backend changed after preparation; prepare again")
		}
		if err := writeFileAtomic(a.backendBackupPath(), original, 0600); err != nil {
			return commandResult{}, err
		}
		if err := rewriteComposeImage(a.cfg.composeFile, a.cfg.backendService, state.TargetImage); err != nil {
			return commandResult{}, err
		}
	}

	activationErr := a.composeUp(ctx, a.cfg.backendService)
	if activationErr == nil {
		activationErr = a.waitHealthy(ctx, a.cfg.backendContainer)
	}
	if activationErr == nil {
		var activeImage string
		activeImage, activationErr = a.containerImage(ctx, a.cfg.backendContainer)
		if activationErr == nil && activeImage != state.TargetImage {
			activationErr = fmt.Errorf("active backend image is %s, expected %s", activeImage, state.TargetImage)
		}
	}
	if activationErr == nil {
		var activeVersion string
		activeVersion, activationErr = a.containerVersion(ctx, a.cfg.backendContainer)
		if activationErr == nil && activeVersion != state.TargetVersion {
			activationErr = fmt.Errorf("active backend reports %s, expected %s", activeVersion, state.TargetVersion)
		}
	}
	if activationErr != nil {
		rollbackErr := a.restoreBackend(ctx, state)
		if rollbackErr != nil {
			return commandResult{}, fmt.Errorf("activation failed: %v; automatic restore also failed: %w", activationErr, rollbackErr)
		}
		return commandResult{}, fmt.Errorf("activation failed and previous backend was restored: %w", activationErr)
	}

	message := fmt.Sprintf("Official backend %s is active and healthy.", state.TargetVersion)
	if err := os.Remove(a.preparedPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		message += " Prepared-state cleanup needs operator attention."
	}
	if err := a.cleanupStaleBackendImages(ctx, state.TargetImage, state.PreviousImage); err != nil {
		message += " Old backend image cleanup needs operator attention."
	}
	return commandResult{
		Message:       message,
		TargetVersion: state.TargetVersion,
		Image:         state.TargetImage,
	}, nil
}

func (a *app) restoreBackend(ctx context.Context, state preparedState) error {
	backup, err := os.ReadFile(a.backendBackupPath())
	if err != nil {
		return err
	}
	info, err := os.Stat(a.cfg.composeFile)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(a.cfg.composeFile, backup, info.Mode().Perm()); err != nil {
		return err
	}
	if err := a.composeUp(ctx, a.cfg.backendService); err != nil {
		return err
	}
	if err := a.waitHealthy(ctx, a.cfg.backendContainer); err != nil {
		return err
	}
	image, err := a.containerImage(ctx, a.cfg.backendContainer)
	if err != nil {
		return err
	}
	if image != state.PreviousImage {
		return fmt.Errorf("restored backend image is %s, expected %s", image, state.PreviousImage)
	}
	version, err := a.containerVersion(ctx, a.cfg.backendContainer)
	if err != nil {
		return err
	}
	if version != state.PreviousVersion {
		return fmt.Errorf("restored backend reports %s, expected %s", version, state.PreviousVersion)
	}
	return nil
}

func (a *app) frontendLogin(ctx context.Context, username string) (commandResult, error) {
	token, err := io.ReadAll(io.LimitReader(os.Stdin, 16*1024))
	if err != nil || strings.TrimSpace(string(token)) == "" {
		return commandResult{}, errors.New("registry token is required on stdin")
	}
	defer func() {
		for i := range token {
			token[i] = 0
		}
	}()
	if _, err := a.runDocker(ctx, bytes.NewReader(token), "login", "ghcr.io", "--username", username, "--password-stdin"); err != nil {
		return commandResult{}, err
	}
	return commandResult{Message: "Registry login succeeded."}, nil
}

func (a *app) frontendLogout(ctx context.Context) (commandResult, error) {
	if _, err := a.runDocker(ctx, nil, "logout", "ghcr.io"); err != nil {
		return commandResult{}, err
	}
	return commandResult{Message: "Registry credentials removed."}, nil
}

func (a *app) activateFrontend(ctx context.Context, image string) (commandResult, error) {
	if !isDigestReference(image, frontendRepository) {
		return commandResult{}, errors.New("frontend image must be the AIFoo GHCR repository at an exact sha256 digest")
	}
	if _, err := a.runDocker(ctx, nil, "pull", image); err != nil {
		return commandResult{}, err
	}
	currentImage, original, err := readComposeImage(a.cfg.composeFile, a.cfg.frontendService)
	if err != nil {
		return commandResult{}, err
	}
	if !isRepositoryReference(currentImage, frontendRepository) {
		return commandResult{}, fmt.Errorf("frontend service is not using %s", frontendRepository)
	}
	if currentImage == image {
		if err := a.waitHealthy(ctx, a.cfg.frontendContainer); err != nil {
			return commandResult{}, err
		}
		activeImage, err := a.containerImage(ctx, a.cfg.frontendContainer)
		if err != nil || activeImage != image {
			return commandResult{}, errors.New("frontend Compose image is not active")
		}
		return commandResult{Message: "AIFoo frontend is already active and healthy.", Image: image}, nil
	}
	if err := writeFileAtomic(a.frontendBackupPath(), original, 0600); err != nil {
		return commandResult{}, err
	}
	if err := rewriteComposeImage(a.cfg.composeFile, a.cfg.frontendService, image); err != nil {
		return commandResult{}, err
	}
	activationErr := a.composeUp(ctx, a.cfg.frontendService)
	if activationErr == nil {
		activationErr = a.waitHealthy(ctx, a.cfg.frontendContainer)
	}
	if activationErr == nil {
		var activeImage string
		activeImage, activationErr = a.containerImage(ctx, a.cfg.frontendContainer)
		if activationErr == nil && activeImage != image {
			activationErr = fmt.Errorf("active frontend image is %s, expected %s", activeImage, image)
		}
	}
	if activationErr != nil {
		info, statErr := os.Stat(a.cfg.composeFile)
		if statErr == nil {
			statErr = writeFileAtomic(a.cfg.composeFile, original, info.Mode().Perm())
		}
		if statErr == nil {
			statErr = a.composeUp(ctx, a.cfg.frontendService)
		}
		if statErr == nil {
			statErr = a.waitHealthy(ctx, a.cfg.frontendContainer)
		}
		if statErr == nil {
			var restoredImage string
			restoredImage, statErr = a.containerImage(ctx, a.cfg.frontendContainer)
			if statErr == nil && restoredImage != currentImage {
				statErr = fmt.Errorf("restored frontend image is %s, expected %s", restoredImage, currentImage)
			}
		}
		if statErr != nil {
			return commandResult{}, fmt.Errorf("frontend activation failed: %v; automatic restore also failed: %w", activationErr, statErr)
		}
		return commandResult{}, fmt.Errorf("frontend activation failed and previous image was restored: %w", activationErr)
	}
	return commandResult{Message: "AIFoo frontend is active and healthy.", Image: image}, nil
}

func (a *app) resolveDigest(ctx context.Context, taggedImage, repository string) (string, error) {
	output, err := a.runDocker(ctx, nil, "image", "inspect", "--format", "{{json .RepoDigests}}", taggedImage)
	if err != nil {
		return "", err
	}
	var digests []string
	if err := json.Unmarshal(bytes.TrimSpace(output), &digests); err != nil {
		return "", fmt.Errorf("decode image digests: %w", err)
	}
	for _, candidate := range digests {
		candidate = strings.TrimPrefix(candidate, "docker.io/")
		if isDigestReference(candidate, repository) {
			return candidate, nil
		}
	}
	return "", errors.New("pulled image did not expose an official repository digest")
}

func (a *app) imageVersion(ctx context.Context, image string) (string, error) {
	output, err := a.runDocker(ctx, nil, "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL", "--entrypoint", "/app/sub2api", image, "--version")
	if err != nil {
		return "", err
	}
	return parseBinaryVersion(output)
}

func (a *app) containerVersion(ctx context.Context, container string) (string, error) {
	output, err := a.runDocker(ctx, nil, "exec", container, "/app/sub2api", "--version")
	if err != nil {
		return "", err
	}
	return parseBinaryVersion(output)
}

func (a *app) containerImage(ctx context.Context, container string) (string, error) {
	output, err := a.runDocker(ctx, nil, "inspect", "--format", "{{.Config.Image}}", container)
	if err != nil {
		return "", err
	}
	image := strings.TrimSpace(string(output))
	if image == "" {
		return "", errors.New("container image is empty")
	}
	return strings.TrimPrefix(image, "docker.io/"), nil
}

func parseBinaryVersion(output []byte) (string, error) {
	match := binaryVersionPattern.FindSubmatch(output)
	if len(match) != 2 {
		return "", errors.New("unable to parse Sub2API binary version")
	}
	return "v" + string(match[1]), nil
}

func (a *app) composeUp(ctx context.Context, service string) error {
	args := append([]string(nil), a.compose[1:]...)
	args = append(args, "-f", a.cfg.composeFile, "up", "-d", "--no-deps", "--force-recreate", service)
	output, err := a.exec.Run(ctx, a.compose[0], args, nil)
	if err != nil {
		return fmt.Errorf("Compose activation failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func (a *app) waitHealthy(ctx context.Context, container string) error {
	deadline := time.Now().Add(a.cfg.healthTimeout)
	for {
		output, err := a.runDocker(ctx, nil, "inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}", container)
		if err == nil {
			status := strings.TrimSpace(string(output))
			if status == "healthy" || status == "running" {
				return nil
			}
			if status == "unhealthy" || status == "exited" || status == "dead" {
				return fmt.Errorf("container %s is %s", container, status)
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("container %s did not become healthy before timeout", container)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

func (a *app) runDocker(ctx context.Context, stdin io.Reader, args ...string) ([]byte, error) {
	output, err := a.exec.Run(ctx, a.docker, args, stdin)
	if err != nil {
		return nil, fmt.Errorf("Docker command failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

func (a *app) cleanupStaleBackendImages(ctx context.Context, keepReferences ...string) error {
	keepIDs := make(map[string]struct{}, len(keepReferences))
	for _, reference := range keepReferences {
		output, err := a.runDocker(ctx, nil, "image", "inspect", "--format", "{{.Id}}", reference)
		if err != nil {
			return fmt.Errorf("inspect retained backend image: %w", err)
		}
		imageID := strings.TrimSpace(string(output))
		if !digestPattern.MatchString(imageID) {
			return errors.New("retained backend image has an invalid image ID")
		}
		keepIDs[imageID] = struct{}{}
	}

	output, err := a.runDocker(ctx, nil, "image", "ls", "--no-trunc", "--format", "{{.Repository}}|{{.Tag}}|{{.ID}}", backendRepository)
	if err != nil {
		return err
	}
	var staleReferences []string
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 3 || parts[0] != backendRepository || !digestPattern.MatchString(parts[2]) {
			return errors.New("Docker returned an invalid backend image listing")
		}
		if parts[1] == "<none>" {
			continue
		}
		if _, keep := keepIDs[parts[2]]; keep {
			continue
		}
		staleReferences = append(staleReferences, parts[0]+":"+parts[1])
	}
	if len(staleReferences) == 0 {
		return nil
	}
	_, err = a.runDocker(ctx, nil, append([]string{"image", "rm"}, staleReferences...)...)
	return err
}

func (a *app) preparedPath() string {
	return filepath.Join(a.cfg.stateDir, "prepared-backend.json")
}

func (a *app) backendBackupPath() string {
	return filepath.Join(a.cfg.stateDir, "compose-before-backend.yml")
}

func (a *app) frontendBackupPath() string {
	return filepath.Join(a.cfg.stateDir, "compose-before-frontend.yml")
}

func isRepositoryReference(image, repository string) bool {
	image = strings.TrimPrefix(strings.TrimSpace(image), "docker.io/")
	return strings.HasPrefix(image, repository+":") || strings.HasPrefix(image, repository+"@")
}

func isDigestReference(image, repository string) bool {
	image = strings.TrimPrefix(strings.TrimSpace(image), "docker.io/")
	prefix := repository + "@"
	return strings.HasPrefix(image, prefix) && digestPattern.MatchString(strings.TrimPrefix(image, prefix))
}

func readComposeImage(path, service string) (string, []byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", nil, err
	}
	document, imageNode, err := composeImageNode(data, service)
	if err != nil {
		return "", nil, err
	}
	_ = document
	return strings.TrimSpace(imageNode.Value), data, nil
}

func rewriteComposeImage(path, service, image string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	document, imageNode, err := composeImageNode(data, service)
	if err != nil {
		return err
	}
	imageNode.Value = image
	imageNode.Tag = "!!str"
	var output bytes.Buffer
	encoder := yaml.NewEncoder(&output)
	encoder.SetIndent(2)
	if err := encoder.Encode(document); err != nil {
		return err
	}
	if err := encoder.Close(); err != nil {
		return err
	}
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, output.Bytes(), info.Mode().Perm())
}

func composeImageNode(data []byte, service string) (*yaml.Node, *yaml.Node, error) {
	var document yaml.Node
	if err := yaml.Unmarshal(data, &document); err != nil {
		return nil, nil, fmt.Errorf("parse Compose YAML: %w", err)
	}
	if len(document.Content) != 1 || document.Content[0].Kind != yaml.MappingNode {
		return nil, nil, errors.New("Compose document must be a mapping")
	}
	services := mappingValue(document.Content[0], "services")
	if services == nil || services.Kind != yaml.MappingNode {
		return nil, nil, errors.New("Compose services mapping is missing")
	}
	serviceNode := mappingValue(services, service)
	if serviceNode == nil || serviceNode.Kind != yaml.MappingNode {
		return nil, nil, fmt.Errorf("Compose service %q is missing", service)
	}
	imageNode := mappingValue(serviceNode, "image")
	if imageNode == nil || imageNode.Kind != yaml.ScalarNode || strings.TrimSpace(imageNode.Value) == "" {
		return nil, nil, fmt.Errorf("Compose service %q has no scalar image", service)
	}
	return &document, imageNode, nil
}

func mappingValue(mapping *yaml.Node, key string) *yaml.Node {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1]
		}
	}
	return nil
}

func writeJSONAtomic(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return writeFileAtomic(path, data, 0600)
}

func readJSON(path string, target any) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 64*1024))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".aifoo-write-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	dir, err := os.Open(directory)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
