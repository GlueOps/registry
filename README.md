# registry

[CNCF Distribution](https://github.com/distribution/distribution) `3.1.1` with two fixes for
the pull-through proxy: it works with `public.ecr.aws`, and it serves its cache without
waiting on an unreachable upstream. Drop-in replacement for `registry:3.1.1`.

```
ghcr.io/glueops/registry
```

## Changes from upstream

**ECR Public.** It rejects `HEAD` on blobs with 401, so stock `registry:3` can't pull any
uncached image through it ([distribution#4383](https://github.com/distribution/distribution/issues/4383)).
This image answers that `HEAD` with a one-byte `GET` instead. If the `GET` fails too, the
original 401 is returned, as upstream would. The fix is in [transport.go](transport.go);
[main.go](main.go) is upstream's plus one assignment.

**Unreachable upstream.** Stock `registry:3` asks the upstream before serving a cached tag,
and waits 15s for it, or 30s per request after a restart, with concurrent requests waiting
in line. Docker gives up at about 30s, so a mirror restarted during an upstream outage serves
nothing ([distribution#3033](https://github.com/distribution/distribution/issues/3033),
[#8](https://github.com/GlueOps/registry/issues/8)). This image waits at most 5s for the
upstream's auth challenge and 10s for a tag lookup, shares one challenge request between
concurrent callers, and for 30s after the last network failure serves cached tags without
checking whether they moved upstream; when the 30s pass, one request checks while the rest
keep serving the cache. Anything not cached still asks the upstream: an uncached tag
during an outage is a 404 after 5–10s. The fix is a patch to upstream's `registry/proxy`
package in [patches/](patches/).

Everything else is upstream, unmodified.

## Usage

```yaml
version: 0.1
storage:
  filesystem:
    rootdirectory: /var/lib/registry
http:
  addr: :5000
proxy:
  remoteurl: https://public.ecr.aws
  ttl: 0
  exec:
    command: /etc/distribution/creds.sh
```

```sh
#!/bin/sh
# creds.sh: anonymous.
cat >/dev/null
echo '{"ServerURL":"","Username":"","Secret":""}'
```

```bash
chmod +x creds.sh   # the registry runs it directly; if it can't, it silently pulls anonymously
docker run -d -p 5000:5000 \
  -v $PWD/config.yml:/etc/distribution/config.yml:ro \
  -v $PWD/creds.sh:/etc/distribution/creds.sh:ro \
  -v registry-cache:/var/lib/registry \
  ghcr.io/glueops/registry:<vX.Y.Z>
```

Things to know (upstream and ECR behaviour):

- **`proxy.exec`**: without it, the registry checks the upstream at startup and panics if it's
  unreachable. With it, the registry starts and serves what's cached.
- **`ttl: 0`**: cached content is never deleted, so disk use only grows.
- **Rate limits**: anonymous ECR Public throttles per IP; several parallel cold pulls can
  return `toomanyrequests`. Authenticating raises the limit: have `creds.sh` return username
  `AWS` and the output of `aws ecr-public get-login-password` as the secret, and set
  `proxy.exec.lifetime: 6h`. The token expires after 12h, and without `lifetime` it is
  never refreshed.
- **Credentials**: anyone who can reach the registry can pull anything the configured
  account can pull.
- **Timeouts**: an upstream that stops responding mid-transfer can still stall uncached
  pulls. Manifest and blob fetches are bounded only by the connection itself.
- **`proxy.exec` during an outage**: the helper is not bounded by the timeouts above and
  runs one at a time. Without `lifetime` it runs once; with it, again after each expiry,
  and a failed run is retried on every token fetch. A helper that itself needs the network
  (`aws ecr-public get-login-password`) stalls every request that fetches a token, including
  the one that discovers an outage, for as long as the helper takes to fail. Keep it quick,
  or have it return cached credentials when the network is down.

## Images

`linux/amd64` and `linux/arm64`.

| Trigger | Tags |
|---|---|
| Release tag `vX.Y.Z` | `vX.Y.Z`, `latest`, `<short-sha>`, `<sha>` |
| Pre-release tag `vX.Y.Z-rc.N` | `vX.Y.Z-rc.N`, `<short-sha>`, `<sha>` |
| Push to `main` | `main`, `<short-sha>`, `<sha>` |
| Push to another branch in this repo | `branch-<name>` (`/` becomes `-`), `<short-sha>`, `<sha>` |
| Pull request from a fork | built and tested, not pushed |

Deploy a `v*` tag, or that tag's digest. Other tags are deleted after 5 days, except the
10 newest.

Releases are cut by [release-please](https://github.com/googleapis/release-please). Every
commit type in [release-please-config.json](release-please-config.json) (`feat`, `fix`,
`chore`, `docs`, `ci`, ...) lands in the next release PR and bumps the patch version
(`0.0.x`). Merging that PR tags `vX.Y.Z`, which builds the image.

## Development

```bash
scripts/test.sh                      # gofmt, go vet, go test -race against the pinned upstream
docker buildx build --load -t registry:dev .
```
