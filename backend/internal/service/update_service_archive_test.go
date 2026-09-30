package service

import "testing"

func TestApplicationArchiveNameExcludesControlPlanePackage(t *testing.T) {
	archiveName := "linux_amd64"
	for _, name := range []string{
		"sub2api_0.2.12_linux_amd64.tar.gz",
		"sub2api_1.0.0_linux_amd64.tar.gz",
	} {
		if !isApplicationArchiveName(name, archiveName) {
			t.Fatalf("expected application archive %q", name)
		}
	}
	for _, name := range []string{
		"sub2api_control_0.2.12_linux_amd64.tar.gz",
		"sub2api_0.2.12-custom_linux_amd64.tar.gz",
		"sub2api_0.2.12_linux_arm64.tar.gz",
	} {
		if isApplicationArchiveName(name, archiveName) {
			t.Fatalf("unexpected application archive %q", name)
		}
	}
}
