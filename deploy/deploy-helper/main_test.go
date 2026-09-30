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
	composeFile  string
	service      string
	activeImage  string
	composeImage string
	versions     map[string]string
	imageIDs     map[string]string
	imageList    string
	removed      []string
	failImage    string
}

func (f *fakeRuntime) Run(_ context.Context, name string, args []string, _ io.Reader) ([]byte, error) {
	if name == "docker-compose" {
		image, _, err := readComposeImage(f.composeFile, f.service)
		if err != nil {
			return nil, err
		}
		if f.composeImage != "" {
			f.activeImage = f.composeImage
		} else {
			f.activeImage = image
		}
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
  postgres:
    image: postgres:18-alpine
`
	if err := os.WriteFile(path, []byte(original), 0640); err != nil {
		t.Fatal(err)
	}
	target := appRepository + "@sha256:" + strings.Repeat("b", 64)
	if err := rewriteComposeImage(path, "sub2api", target); err != nil {
		t.Fatal(err)
	}
	appImage, _, err := readComposeImage(path, "sub2api")
	if err != nil || appImage != target {
		t.Fatalf("app image = %q, err = %v", appImage, err)
	}
	postgres, _, err := readComposeImage(path, "postgres")
	if err != nil || postgres != "postgres:18-alpine" {
		t.Fatalf("postgres = %q, err = %v", postgres, err)
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
	valid := appRepository + "@sha256:" + strings.Repeat("a", 64)
	if !isDigestReference(valid, appRepository) {
		t.Fatal("expected exact app digest to be accepted")
	}
	for _, value := range []string{
		appRepository + ":latest",
		"ghcr.io/other/repository@sha256:" + strings.Repeat("a", 64),
		appRepository + "@sha256:" + strings.Repeat("A", 64),
	} {
		if isDigestReference(value, appRepository) {
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

func TestAppActivationUsesPreparedDigest(t *testing.T) {
	application, runtime, state, composePath := newActivationTestApp(t)

	result, err := application.activateApp(context.Background())
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
	if len(runtime.removed) != 1 || runtime.removed[0] != appRepository+":0.1.181" {
		t.Fatalf("removed images = %v", runtime.removed)
	}
}

func TestAppActivationAcceptsInterpolatedComposeImage(t *testing.T) {
	application, runtime, state, composePath := newActivationTestApp(t)
	previousComposeImage := "${SUB2API_IMAGE:-" + state.PreviousImage + "}"
	compose := "services:\n  sub2api:\n    image: " + previousComposeImage + "\n"
	if err := os.WriteFile(composePath, []byte(compose), 0640); err != nil {
		t.Fatal(err)
	}
	state.PreviousComposeImage = previousComposeImage
	if err := writeJSONAtomic(application.preparedPath(), state); err != nil {
		t.Fatal(err)
	}
	runtime.composeImage = state.TargetImage

	if _, err := application.activateApp(context.Background()); err != nil {
		t.Fatal(err)
	}
	image, _, err := readComposeImage(composePath, "sub2api")
	if err != nil || image != state.TargetImage || runtime.activeImage != state.TargetImage {
		t.Fatalf("compose = %q, runtime = %q, err = %v", image, runtime.activeImage, err)
	}
}

func TestCleanupStaleAppImagesKeepsEveryTagForCurrentAndPreviousIDs(t *testing.T) {
	current := appRepository + "@sha256:" + strings.Repeat("a", 64)
	previous := appRepository + "@sha256:" + strings.Repeat("b", 64)
	currentID := "sha256:" + strings.Repeat("1", 64)
	previousID := "sha256:" + strings.Repeat("2", 64)
	runtime := &fakeRuntime{
		imageIDs: map[string]string{current: currentID, previous: previousID},
		imageList: strings.Join([]string{
			appRepository + "|0.1.183|" + currentID,
			appRepository + "|stable|" + currentID,
			appRepository + "|0.1.182|" + previousID,
			appRepository + "|0.1.181|sha256:" + strings.Repeat("3", 64),
		}, "\n") + "\n",
	}
	application := &app{exec: runtime, docker: "docker"}

	if err := application.cleanupStaleAppImages(context.Background(), current, previous); err != nil {
		t.Fatal(err)
	}
	if len(runtime.removed) != 1 || runtime.removed[0] != appRepository+":0.1.181" {
		t.Fatalf("removed images = %v", runtime.removed)
	}
}

func TestAppActivationRestoresPreviousImageOnHealthFailure(t *testing.T) {
	application, runtime, state, composePath := newActivationTestApp(t)
	runtime.failImage = state.TargetImage

	_, err := application.activateApp(context.Background())
	if err == nil || !strings.Contains(err.Error(), "previous app was restored") {
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
	previousImage := appRepository + "@sha256:" + strings.Repeat("a", 64)
	targetImage := appRepository + "@sha256:" + strings.Repeat("b", 64)
	compose := "services:\n  sub2api:\n    image: " + previousImage + "\n"
	if err := os.WriteFile(composePath, []byte(compose), 0640); err != nil {
		t.Fatal(err)
	}
	cfg := configuration{
		composeFile:   composePath,
		stateDir:      filepath.Join(directory, "state"),
		appService:    "sub2api",
		appContainer:  "sub2api",
		healthTimeout: 50 * time.Millisecond,
	}
	state := preparedState{
		TargetVersion:        "v0.1.183",
		TargetImage:          targetImage,
		PreviousVersion:      "v0.1.182",
		PreviousImage:        previousImage,
		PreviousComposeImage: previousImage,
		PreparedAt:           time.Now().UTC(),
	}
	if err := writeJSONAtomic(filepath.Join(cfg.stateDir, "prepared-app.json"), state); err != nil {
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
		imageList: appRepository + "|0.1.183|sha256:" + strings.Repeat("2", 64) + "\n" +
			appRepository + "|0.1.182|sha256:" + strings.Repeat("1", 64) + "\n" +
			appRepository + "|0.1.181|sha256:" + strings.Repeat("3", 64) + "\n",
	}
	application := &app{
		cfg:     cfg,
		exec:    runtime,
		docker:  "docker",
		compose: []string{"docker-compose"},
	}
	return application, runtime, state, composePath
}
