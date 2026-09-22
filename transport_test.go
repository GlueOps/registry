package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// authLayer stands in for upstream's auth transport: it adds credentials to a
// clone of requests for one host, like the real one does for a host with a
// known challenge.
type authLayer struct{ host string }

func (a authLayer) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Host == a.host {
		req = req.Clone(req.Context())
		req.Header.Set("Authorization", "Bearer t")
	}
	return http.DefaultTransport.RoundTrip(req)
}

type fakeECR struct {
	registry, cdn         *httptest.Server
	cdnHeads, cdnAuthSeen atomic.Int32
	blob                  []byte
	cdnHandler            http.HandlerFunc // overrides the default CDN behaviour
}

// newFakeECR serves a blob the way public.ecr.aws does: HEAD is always 401,
// an authorised GET redirects to a CDN that accepts only unauthenticated GET.
func newFakeECR(t *testing.T, blob []byte) *fakeECR {
	t.Helper()
	f := &fakeECR{blob: blob}
	f.cdn = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			f.cdnAuthSeen.Add(1)
			http.Error(w, "credentials sent to CDN", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet {
			f.cdnHeads.Add(1)
			http.Error(w, "signed for GET only", http.StatusForbidden)
			return
		}
		if f.cdnHandler != nil {
			f.cdnHandler(w, r)
			return
		}
		http.ServeContent(w, r, "blob", time.Time{}, bytes.NewReader(f.blob))
	}))
	f.registry = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v2/":
			w.Header().Set("Www-Authenticate", `Bearer realm="`+f.registryURL()+`/token",service="fake"`)
			w.WriteHeader(http.StatusUnauthorized)
		case r.URL.Path == "/token":
			_, _ = io.WriteString(w, `{"token":"t","expires_in":300}`)
		case strings.Contains(r.URL.Path, "/blobs/"):
			if r.Method == http.MethodHead || r.Header.Get("Authorization") != "Bearer t" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			// A different hostname from the registry, as CloudFront is from ECR.
			http.Redirect(w, r, strings.Replace(f.cdn.URL, "127.0.0.1", "localhost", 1)+"/signed", http.StatusTemporaryRedirect)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(func() { f.registry.Close(); f.cdn.Close() })
	return f
}

func (f *fakeECR) registryURL() string { return f.registry.URL }

func (f *fakeECR) client() *http.Client {
	u, _ := url.Parse(f.registry.URL)
	return &http.Client{Transport: wrapBlobHeadFallback(authLayer{host: u.Host})}
}

func head(t *testing.T, c *http.Client, u string) *http.Response {
	t.Helper()
	resp, err := c.Head(u)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestBlobHeadFallsBackToRangedGet(t *testing.T) {
	f := newFakeECR(t, bytes.Repeat([]byte("x"), 1234))
	resp := head(t, f.client(), f.registry.URL+"/v2/repo/blobs/sha256:abc")

	if resp.StatusCode != http.StatusOK || resp.ContentLength != 1234 || resp.Header.Get("Content-Length") != "1234" {
		t.Fatalf("got %d, length %d / %q", resp.StatusCode, resp.ContentLength, resp.Header.Get("Content-Length"))
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/octet-stream" {
		t.Errorf("Content-Type %q", ct)
	}
	if n := f.cdnAuthSeen.Load(); n != 0 {
		t.Errorf("CDN received credentials %d times", n)
	}
	if n := f.cdnHeads.Load(); n != 0 {
		t.Errorf("CDN received %d HEADs", n)
	}
}

func TestRangeIgnoredDoesNotReadWholeBlob(t *testing.T) {
	const size = 64 << 20
	var written atomic.Int64
	f := newFakeECR(t, nil)
	f.cdnHandler = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Length", "67108864")
		chunk := make([]byte, 32<<10)
		for written.Load() < size {
			n, err := w.Write(chunk)
			written.Add(int64(n))
			if err != nil {
				return
			}
		}
	}
	resp := head(t, f.client(), f.registry.URL+"/v2/repo/blobs/sha256:abc")
	if resp.StatusCode != http.StatusOK || resp.ContentLength != size {
		t.Fatalf("got %d, length %d", resp.StatusCode, resp.ContentLength)
	}
	if w := written.Load(); w >= size {
		t.Fatalf("whole blob was read (%d bytes)", w)
	}
}

func TestChallengeWithoutCredentialsPassesThrough(t *testing.T) {
	f := newFakeECR(t, []byte("x"))
	c := &http.Client{Transport: wrapBlobHeadFallback(http.DefaultTransport)}
	resp := head(t, c, f.registry.URL+"/v2/repo/blobs/sha256:abc")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("got %d, want the 401 challenge", resp.StatusCode)
	}
}

func TestOtherResponsesUntouched(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if strings.Contains(r.URL.Path, "/manifests/") {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()
	u, _ := url.Parse(srv.URL)
	c := &http.Client{Transport: wrapBlobHeadFallback(authLayer{host: u.Host})}

	if resp := head(t, c, srv.URL+"/v2/repo/manifests/latest"); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("manifest HEAD: got %d", resp.StatusCode)
	}
	if resp := head(t, c, srv.URL+"/v2/repo/blobs/sha256:abc"); resp.StatusCode != http.StatusNotFound {
		t.Errorf("blob HEAD 404: got %d", resp.StatusCode)
	}
}

func TestFallbackErrorIsReturnedAsIs(t *testing.T) {
	f := newFakeECR(t, nil)
	f.cdnHandler = func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "Rate exceeded", http.StatusTooManyRequests)
	}
	resp := head(t, f.client(), f.registry.URL+"/v2/repo/blobs/sha256:abc")
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusTooManyRequests || !strings.Contains(string(body), "Rate exceeded") {
		t.Fatalf("got %d %q", resp.StatusCode, body)
	}
	if resp.Request.Method != http.MethodHead {
		t.Errorf("Request is %s, want the original HEAD", resp.Request.Method)
	}
}

func TestSizeFromContentRange(t *testing.T) {
	for in, want := range map[string]int64{
		"bytes 0-0/12345": 12345,
		"bytes 0-0/*":     -1,
		"":                -1,
		"garbage":         -1,
	} {
		if got := sizeFromContentRange(in); got != want {
			t.Errorf("%q: got %d, want %d", in, got, want)
		}
	}
}

// A 401 that the GET also gets is a real auth failure, not the ECR quirk:
// the caller must still see 401, not the GET's 401/403/404.
func TestAuthFailureStaysUnauthorized(t *testing.T) {
	for _, getStatus := range []int{http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodHead {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.WriteHeader(getStatus)
		}))
		u, _ := url.Parse(srv.URL)
		c := &http.Client{Transport: wrapBlobHeadFallback(authLayer{host: u.Host})}
		if resp := head(t, c, srv.URL+"/v2/private/repo/blobs/sha256:abc"); resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("GET %d: got %d, want 401", getStatus, resp.StatusCode)
		}
		srv.Close()
	}
}

func TestFallbackNetworkErrorIsReturned(t *testing.T) {
	f := newFakeECR(t, nil)
	f.cdnHandler = func(w http.ResponseWriter, r *http.Request) {
		conn, _, _ := w.(http.Hijacker).Hijack()
		conn.Close()
	}
	resp, err := f.client().Head(f.registry.URL + "/v2/repo/blobs/sha256:abc")
	if err == nil {
		resp.Body.Close()
		t.Fatalf("got %d, want an error", resp.StatusCode)
	}
}

func TestUnknownSizeHasNoContentLength(t *testing.T) {
	f := newFakeECR(t, nil)
	f.cdnHandler = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Range", "bytes 0-0/*")
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write([]byte{0})
	}
	resp := head(t, f.client(), f.registry.URL+"/v2/repo/blobs/sha256:abc")
	if resp.Header.Get("Content-Length") != "" || resp.ContentLength != -1 {
		t.Fatalf("got length %q / %d; want none, so the caller fails cleanly", resp.Header.Get("Content-Length"), resp.ContentLength)
	}
}

func TestFallbackErrorBodyIsCapped(t *testing.T) {
	f := newFakeECR(t, nil)
	f.cdnHandler = func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write(bytes.Repeat([]byte("x"), 1<<20))
	}
	resp := head(t, f.client(), f.registry.URL+"/v2/repo/blobs/sha256:abc")
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusServiceUnavailable || len(body) > 64<<10 {
		t.Fatalf("got %d with %d bytes", resp.StatusCode, len(body))
	}
}

func TestBlobPath(t *testing.T) {
	for path, want := range map[string]bool{
		"/v2/busybox/blobs/sha256:abc":                       true,
		"/v2/docker/library/busybox/blobs/sha256:abc":        true,
		"/v2/a/b/c/blobs/sha512:" + strings.Repeat("f", 128): true,
		"/v2/busybox/blobs/uploads/":                         false,
		"/v2/busybox/blobs/uploads/0f1e2d":                   false,
		"/v2/busybox/manifests/sha256:abc":                   false,
		"/v2/busybox/manifests/latest":                       false,
	} {
		if got := blobPath.MatchString(path); got != want {
			t.Errorf("%s: got %v, want %v", path, got, want)
		}
	}
}
