package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fakeRuntime struct {
	composeFile string
	service     string
	activeImage string
	versions    map[string]string
	imageIDs    map[string]string
	imageList   string
	removed     []string
	failImage   string
}

func (f *fakeRuntime) Run(_ context.Context, name string, args []string, _ io.Reader) ([]byte, error) {
	if name == "docker-compose" {
		image, _, err := readComposeImage(f.composeFile, f.service)
		if err != nil {
			return nil, err
		}
		f.activeImage = image
		return []byte("started"), nil
	}
	if name != "docker" || len(args) == 0 {
		return nil, fmt.Errorf("unexpected command %s %v", name, args)
	}
	switch args[0] {
	case "image":
		if len(args) < 2 {
			return nil, errors.New("invalid image command")
		}
		switch args[1] {
		case "inspect":
			imageID := f.imageIDs[args[len(args)-1]]
			if imageID == "" {
				return nil, errors.New("image unavailable")
			}
			return []byte(imageID + "\n"), nil
		case "ls":
			return []byte(f.imageList), nil
		case "rm":
			f.removed = append(f.removed, args[2:]...)
			return []byte("removed"), nil
		default:
			return nil, fmt.Errorf("unexpected Docker image command %v", args)
		}
	case "inspect":
		if len(args) < 3 {
			return nil, errors.New("invalid inspect")
		}
		if strings.Contains(args[2], ".Config.Image") {
			return []byte(f.activeImage + "\n"), nil
		}
		if f.activeImage == f.failImage {
			return []byte("unhealthy\n"), nil
		}
		return []byte("healthy\n"), nil
	case "exec":
		version := f.versions[f.activeImage]
		if version == "" {
			return nil, errors.New("version unavailable")
		}
		return []byte("Sub2API " + strings.TrimPrefix(version, "v") + "\n"), nil
	default:
		return nil, fmt.Errorf("unexpected Docker command %v", args)
	}
}

func TestComposeImageRewriteChangesOnlySelectedService(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "docker-compose.yml")
	original := `services:
  sub2api:
    image: ghcr.io/jayhome137/sub2api:0.1.182
    environment:
      - VALUE=${VALUE:-unchanged}
  frontend:
    image: ghcr.io/jayhome137/sub2api-frontend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
`
	if err := os.WriteFile(path, []byte(original), 0640); err != nil {
		t.Fatal(err)
	}
	target := "ghcr.io/jayhome137/sub2api@sha256:" + strings.Repeat("b", 64)
	if err := rewriteComposeImage(path, "sub2api", target); err != nil {
		t.Fatal(err)
	}
	backend, _, err := readComposeImage(path, "sub2api")
	if err != nil || backend != target {
		t.Fatalf("backend = %q, err = %v", backend, err)
	}
	frontend, _, err := readComposeImage(path, "frontend")
	if err != nil || !strings.Contains(frontend, strings.Repeat("a", 64)) {
		t.Fatalf("frontend = %q, err = %v", frontend, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "${VALUE:-unchanged}") {
		t.Fatalf("environment interpolation changed:\n%s", data)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0640 {
		t.Fatalf("mode = %v, err = %v", info.Mode().Perm(), err)
	}
}

func TestImageReferenceValidation(t *testing.T) {
	valid := frontendRepository + "@sha256:" + strings.Repeat("a", 64)
	if !isDigestReference(valid, frontendRepository) {
		t.Fatal("expected exact frontend digest to be accepted")
	}
	for _, value := range []string{
		frontendRepository + ":latest",
		"ghcr.io/other/repository@sha256:" + strings.Repeat("a", 64),
		frontendRepository + "@sha256:" + strings.Repeat("A", 64),
	} {
		if isDigestReference(value, frontendRepository) {
			t.Fatalf("unexpected accepted reference %q", value)
		}
	}
}

func TestParseBinaryVersion(t *testing.T) {
	version, err := parseBinaryVersion([]byte("2026/08/25 12:00:00 Sub2API 0.1.182 (commit: abc)\n"))
	if err != nil || version != "v0.1.182" {
		t.Fatalf("version = %q, err = %v", version, err)
	}
}

func TestComposeServiceMustExist(t *testing.T) {
	_, _, err := composeImageNode([]byte("services:\n  frontend:\n    image: nginx:latest\n"), "sub2api")
	if err == nil {
		t.Fatal("expected missing service error")
	}
}

func TestBackendActivationUsesPreparedDigest(t *testing.T) {
	application, runtime, state, composePath := newActivationTestApp(t)

	result, err := application.activateBackend(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.TargetVersion != state.TargetVersion || result.Image != state.TargetImage {
		t.Fatalf("result = %#v", result)
	}
	image, _, err := readComposeImage(composePath, "sub2api")
	if err != nil || image != state.TargetImage || runtime.activeImage != state.TargetImage {
		t.Fatalf("compose = %q, runtime = %q, err = %v", image, runtime.activeImage, err)
	}
	if _, err := os.Stat(application.preparedPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("prepared state still exists: %v", err)
	}
	if len(runtime.removed) != 1 || runtime.removed[0] != backendRepository+":0.1.181" {
		t.Fatalf("removed images = %v", runtime.removed)
	}
}

func TestCleanupStaleBackendImagesKeepsEveryTagForCurrentAndPreviousIDs(t *testing.T) {
	current := backendRepository + "@sha256:" + strings.Repeat("a", 64)
	previous := backendRepository + "@sha256:" + strings.Repeat("b", 64)
	currentID := "sha256:" + strings.Repeat("1", 64)
	previousID := "sha256:" + strings.Repeat("2", 64)
	runtime := &fakeRuntime{
		imageIDs: map[string]string{current: currentID, previous: previousID},
		imageList: strings.Join([]string{
			backendRepository + "|0.1.183|" + currentID,
			backendRepository + "|stable|" + currentID,
			backendRepository + "|0.1.182|" + previousID,
			backendRepository + "|0.1.181|sha256:" + strings.Repeat("3", 64),
		}, "\n") + "\n",
	}
	application := &app{exec: runtime, docker: "docker"}

	if err := application.cleanupStaleBackendImages(context.Background(), current, previous); err != nil {
		t.Fatal(err)
	}
	if len(runtime.removed) != 1 || runtime.removed[0] != backendRepository+":0.1.181" {
		t.Fatalf("removed images = %v", runtime.removed)
	}
}

func TestBackendActivationRestoresPreviousImageOnHealthFailure(t *testing.T) {
	application, runtime, state, composePath := newActivationTestApp(t)
	runtime.failImage = state.TargetImage

	_, err := application.activateBackend(context.Background())
	if err == nil || !strings.Contains(err.Error(), "previous backend was restored") {
		t.Fatalf("activation error = %v", err)
	}
	image, _, readErr := readComposeImage(composePath, "sub2api")
	if readErr != nil || image != state.PreviousImage || runtime.activeImage != state.PreviousImage {
		t.Fatalf("compose = %q, runtime = %q, err = %v", image, runtime.activeImage, readErr)
	}
	if _, statErr := os.Stat(application.preparedPath()); statErr != nil {
		t.Fatalf("prepared state should remain for a retry: %v", statErr)
	}
}

func newActivationTestApp(t *testing.T) (*app, *fakeRuntime, preparedState, string) {
	t.Helper()
	directory := t.TempDir()
	composePath := filepath.Join(directory, "docker-compose.yml")
	previousImage := backendRepository + "@sha256:" + strings.Repeat("a", 64)
	targetImage := backendRepository + "@sha256:" + strings.Repeat("b", 64)
	compose := "services:\n  sub2api:\n    image: " + previousImage + "\n"
	if err := os.WriteFile(composePath, []byte(compose), 0640); err != nil {
		t.Fatal(err)
	}
	cfg := configuration{
		composeFile:       composePath,
		stateDir:          filepath.Join(directory, "state"),
		backendService:    "sub2api",
		backendContainer:  "sub2api",
		frontendService:   "frontend",
		frontendContainer: "sub2api-frontend",
		healthTimeout:     50 * time.Millisecond,
	}
	state := preparedState{
		TargetVersion:   "v0.1.183",
		TargetImage:     targetImage,
		PreviousVersion: "v0.1.182",
		PreviousImage:   previousImage,
		PreparedAt:      time.Now().UTC(),
	}
	if err := writeJSONAtomic(filepath.Join(cfg.stateDir, "prepared-backend.json"), state); err != nil {
		t.Fatal(err)
	}
	runtime := &fakeRuntime{
		composeFile: composePath,
		service:     "sub2api",
		activeImage: previousImage,
		versions: map[string]string{
			previousImage: "v0.1.182",
			targetImage:   "v0.1.183",
		},
		imageIDs: map[string]string{
			previousImage: "sha256:" + strings.Repeat("1", 64),
			targetImage:   "sha256:" + strings.Repeat("2", 64),
		},
		imageList: backendRepository + "|0.1.183|sha256:" + strings.Repeat("2", 64) + "\n" +
			backendRepository + "|0.1.182|sha256:" + strings.Repeat("1", 64) + "\n" +
			backendRepository + "|0.1.181|sha256:" + strings.Repeat("3", 64) + "\n",
	}
	application := &app{
		cfg:     cfg,
		exec:    runtime,
		docker:  "docker",
		compose: []string{"docker-compose"},
	}
	return application, runtime, state, composePath
}
