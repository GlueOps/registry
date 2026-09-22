# AGENTS.md

Guidance for anyone, human or AI, changing this repo.

## What this is

Upstream Distribution, built from a pinned commit, with one change: a fallback for ECR
Public rejecting blob `HEAD` requests ([distribution#4383](https://github.com/distribution/distribution/issues/4383)).
Stay as close to upstream as possible. Don't add features; raise them upstream.

## Why there is no go.mod

The fix uses upstream's `internal/client/transport`, and Go only allows `internal/`
imports from inside the same module. So our `.go` files are compiled as upstream's
`cmd/registry` package (see the Dockerfile), and upstream's `go.mod`/`go.sum`/`vendor/`
pin all dependencies. A `go.mod` here would make the fix impossible without forking upstream.

Run the tests with `scripts/test.sh`: it checks out the pinned upstream into `.upstream/`
(git-ignored), copies our files in, and runs `gofmt`, `go vet` and `go test -race` in the
pinned Go image. Edit the files in the repo root; `.upstream/` is reset on every run.

## Invariants

- `main.go` is upstream's `cmd/registry/main.go` plus the line setting
  `transport.DefaultTransportWrapper`. Diff it against upstream on every version bump.
- Never modify `http.DefaultTransport` or `http.DefaultClient`. Upstream code type-asserts
  `http.DefaultTransport` (notifications, S3/Azure `skipverify`), and the AWS SDK uses
  `http.DefaultClient` for S3. The previous version of this repo broke both.
- `transport.DefaultTransportWrapper` is only applied to the proxy's upstream requests
  (`registry/proxy/proxyregistry.go`). It sits above the auth layer: credentials are added
  by the next `RoundTripper`, and `resp.Request` is the request that carried them.
- The fallback only fires on a blob `HEAD` that got 401 after credentials were sent.
  A 401 without credentials is an auth challenge and passes through.
- If the fallback `GET` gets 401/403/404, return the original 401: that's a real auth
  failure, and callers must see what upstream would have returned. Other failures (429,
  5xx) are passed through, with the body capped at 64KB.
- Never read a fallback response body past 64KB: a server may ignore `Range`.
- `-ldflags -X` must name upstream's `version` package (that's where the variables live);
  only the values identify this repo (`mainpkg`, `VERSION`, `REVISION`).

## Pins

Bump together.

| What | Where |
|---|---|
| Distribution commit | `Dockerfile` `DISTRIBUTION_COMMIT`, plus every `3.1.1` in the Dockerfile, workflow (`VERSION`) and README |
| Go images (must match upstream's `GO_VERSION`/`ALPINE_VERSION`) | `Dockerfile` (build stage and `GO_TEST_IMAGE`) |
| Base image `registry:X.Y.Z` (must match the commit) | `Dockerfile` |
| Actions (SHA + release comment), buildx, BuildKit, runner `ubuntu-24.04` | `.github/workflows/` |

```bash
git ls-remote https://github.com/distribution/distribution 'refs/tags/vX.Y.Z^{}'   # commit
docker buildx imagetools inspect registry:X.Y.Z                                       # digest
```

## Testing

- `transport_test.go`: unit tests for the fallback.
- `proxy_test.go`: pulls a blob through upstream's real proxy from a fake ECR (HEAD 401,
  GET 307 to a CDN that rejects HEAD and credentials). A negative control checks that
  stock upstream fails against the fake. Uses the filesystem driver: the inmemory driver
  corrupts multi-chunk proxy writes even without our code.
- `scripts/test.sh` runs them with `-race`; CI runs the same script. The Docker build also
  runs them (without cgo).
- Before merging a behaviour change, also pull real images from `public.ecr.aws` through
  the image. Pull sequentially: anonymous ECR rate-limits per IP.
- Lint workflows: `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint`.

## Releases

release-please (GlueOps convention, see github.com/glueops/skills `release-please`):
`.github/workflows/release-please.yaml` with the `public-release-please` App token,
`release-please-config.json` + `.release-please-manifest.json`, plain `vX.Y.Z` tags.

- A release PR opens whenever the changelog is non-empty, so every commit type listed (and
  not hidden) in `changelog-sections` releases, not just feat/fix. The list includes the
  org check's `pref`, `breaking` and `major`.
- Until 1.0 every release bumps the patch version (`bump-patch-for-minor-pre-major`). A
  breaking change (`!` or a `BREAKING CHANGE:` footer; a `breaking:`/`major:` type alone
  doesn't count) bumps the minor.
- The first release is `v0.0.1` (`initial-version`). Never create tags or releases by hand.
- PRs are rebase-merged, so every commit subject on the branch becomes a changelog line:
  keep subjects accurate for what finally merges.

## Conventions

- Only release-please creates `v*` tags, and the build refuses to publish a tag
  that isn't an ancestor of `main`. Branch images are published as `branch-<name>`,
  so a branch can't take `latest` or `main`.
- Image tags keep the `v` prefix (`vX.Y.Z`). The workflow uses `type=semver,pattern={{raw}}`;
  `{{version}}` would drop the `v` from pre-releases and the cleanup would delete them.
- Commit messages are conventional commits. The org PR check allows only: `fix`, `docs`,
  `style`, `refactor`, `test`, `chore`, `pref` (sic; `perf` is rejected), `ci`, `feat`,
  `breaking`, `major`, `revert`.
- Keep docs short. README is for users; maintainer detail goes here.

## When to remove this repo

When upstream fixes #4383, switch to stock `registry` and archive this.
