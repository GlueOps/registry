package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/distribution/distribution/v3/configuration"
	"github.com/distribution/distribution/v3/internal/client/transport"
	"github.com/distribution/distribution/v3/registry/proxy"
	"github.com/distribution/distribution/v3/registry/storage"
	"github.com/distribution/distribution/v3/registry/storage/driver/filesystem"
	"github.com/distribution/reference"
	"github.com/opencontainers/go-digest"
)

// pullThroughFakeECR runs a blob through upstream's real pull-through proxy
// against a fake ECR, with the given transport wrapper installed. It sets the
// global transport.DefaultTransportWrapper, so tests here must not t.Parallel().
func pullThroughFakeECR(t *testing.T, wrapper func(http.RoundTripper) http.RoundTripper) (*fakeECR, []byte, error) {
	t.Helper()
	blob := make([]byte, 256<<10)
	_, _ = rand.Read(blob)
	dgst := digest.FromBytes(blob)
	f := newFakeECR(t, blob)

	prev := transport.DefaultTransportWrapper
	transport.DefaultTransportWrapper = wrapper
	t.Cleanup(func() { transport.DefaultTransportWrapper = prev })

	ctx := context.Background()
	// Filesystem, as in production. (The inmemory driver corrupts multi-chunk
	// proxy writes even with stock upstream, so it can't be used here.)
	driver := filesystem.New(filesystem.DriverParameters{RootDirectory: t.TempDir(), MaxThreads: 100})
	local, err := storage.NewRegistry(ctx, driver)
	if err != nil {
		t.Fatal(err)
	}
	noTTL := time.Duration(0)
	reg, err := proxy.NewRegistryPullThroughCache(ctx, local, driver, configuration.Proxy{RemoteURL: f.registry.URL, TTL: &noTTL})
	if err != nil {
		t.Fatal(err)
	}
	name, _ := reference.WithName("library/test")
	repo, err := reg.Repository(ctx, name)
	if err != nil {
		t.Fatal(err)
	}
	blobs := repo.Blobs(ctx)

	desc, err := blobs.Stat(ctx, dgst)
	if err != nil {
		return f, nil, err
	}
	if desc.Size != int64(len(blob)) {
		t.Fatalf("Stat size %d, want %d", desc.Size, len(blob))
	}
	rec := httptest.NewRecorder()
	if err := blobs.ServeBlob(ctx, rec, httptest.NewRequest("GET", "/", nil), dgst); err != nil {
		t.Fatalf("ServeBlob: %v", err)
	}
	return f, rec.Body.Bytes(), nil
}

func TestProxyPullsFromECRWithFallback(t *testing.T) {
	f, got, err := pullThroughFakeECR(t, wrapBlobHeadFallback)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if !bytes.Equal(got, f.blob) {
		t.Fatalf("served %d bytes, want the %d-byte blob", len(got), len(f.blob))
	}
	if n := f.cdnAuthSeen.Load(); n != 0 {
		t.Errorf("CDN received credentials %d times", n)
	}
}

// Negative control: without the fallback, stock upstream fails against the fake,
// so the fake really reproduces the ECR behaviour.
func TestProxyFailsWithoutFallback(t *testing.T) {
	identity := func(rt http.RoundTripper) http.RoundTripper { return rt }
	if _, _, err := pullThroughFakeECR(t, identity); err == nil {
		t.Fatal("stock proxy pulled from the fake ECR; the fake does not reproduce the bug")
	}
}
