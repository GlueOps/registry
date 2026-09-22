package main

import (
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

// public.ecr.aws answers HEAD on a blob with 401, even with a valid token
// (distribution#4383). The proxy HEADs every blob before fetching it, so every
// uncached pull fails. GET works, so answer the HEAD with a one-byte GET.
//
// Installed as transport.DefaultTransportWrapper, which upstream applies only to
// the proxy's requests to its upstream registry. It sits above the auth layer:
// the next RoundTripper adds credentials.

var blobPath = regexp.MustCompile(`^/v2/.+/blobs/[^/]+:[^/]+$`)

type blobHeadFallback struct {
	next http.RoundTripper
}

func wrapBlobHeadFallback(rt http.RoundTripper) http.RoundTripper {
	return &blobHeadFallback{next: rt}
}

func (b *blobHeadFallback) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := b.next.RoundTrip(req)
	if err != nil || req.Method != http.MethodHead || resp.StatusCode != http.StatusUnauthorized ||
		!blobPath.MatchString(req.URL.Path) || !sentCredentials(resp) {
		return resp, err
	}
	get, err := b.headViaGet(req)
	if err != nil {
		resp.Body.Close()
		return nil, err
	}
	switch get.StatusCode {
	case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound:
		// Not the ECR quirk: a real auth failure. Report the original 401.
		drain(get)
		return resp, nil
	}
	resp.Body.Close()
	return get, nil
}

// sentCredentials reports whether the rejected request carried credentials. The
// auth layer adds them to a clone, which the transport records as resp.Request.
// A 401 without credentials is an ordinary auth challenge and is left alone.
func sentCredentials(resp *http.Response) bool {
	return resp.Request != nil && resp.Request.Header.Get("Authorization") != ""
}

// headViaGet fetches the first byte of the blob and reports its size as a HEAD
// response would. Redirects (ECR sends the blob to CloudFront, signed for GET
// only) are followed by a standard client; credentials are only added for the
// registry's own host.
func (b *blobHeadFallback) headViaGet(head *http.Request) (*http.Response, error) {
	get, err := http.NewRequestWithContext(head.Context(), http.MethodGet, head.URL.String(), nil)
	if err != nil {
		return nil, err
	}
	if head.Header != nil {
		get.Header = head.Header.Clone()
	}
	get.Header.Set("Range", "bytes=0-0")

	resp, err := (&http.Client{Transport: b.next}).Do(get)
	if err != nil {
		return nil, err
	}

	var size int64
	switch resp.StatusCode {
	case http.StatusPartialContent:
		size = sizeFromContentRange(resp.Header.Get("Content-Range"))
	case http.StatusOK:
		size = resp.ContentLength
	default:
		// Rate limited, CDN error: return it so the caller sees why. The caller
		// reads error bodies in full, so cap it.
		resp.Body = limitedBody{io.LimitReader(resp.Body, 64<<10), resp.Body}
		resp.Request = head
		return resp, nil
	}
	drain(resp)

	out := &http.Response{
		Status:        "200 OK",
		StatusCode:    http.StatusOK,
		Proto:         "HTTP/1.1",
		ProtoMajor:    1,
		ProtoMinor:    1,
		Header:        http.Header{"Content-Type": {"application/octet-stream"}},
		ContentLength: size,
		Body:          http.NoBody,
		Request:       head,
	}
	if size >= 0 {
		out.Header.Set("Content-Length", strconv.FormatInt(size, 10))
	}
	return out, nil
}

type limitedBody struct {
	io.Reader
	io.Closer
}

// sizeFromContentRange parses "bytes 0-0/12345"; -1 if the total is unknown.
func sizeFromContentRange(v string) int64 {
	i := strings.LastIndexByte(v, '/')
	if i < 0 {
		return -1
	}
	n, err := strconv.ParseInt(v[i+1:], 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// drain reads at most 64KB so small bodies can reuse the connection, then
// closes; a server that ignored Range is never read to the end.
func drain(resp *http.Response) {
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
}
