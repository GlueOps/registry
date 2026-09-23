# AGENTS.md

Guidance for anyone, human or AI, changing this repo.

## What this is

Upstream Distribution, built from a pinned commit, with two bug fixes for the pull-through
proxy:

- ECR Public rejects blob `HEAD` ([distribution#4383](https://github.com/distribution/distribution/issues/4383)):
  a fallback in `transport.go`, installed by `main.go`.
- An unreachable upstream stalls cached pulls for 15–30s and a restart during the outage
  makes every pull fail ([distribution#3033](https://github.com/distribution/distribution/issues/3033),
  [#8](https://github.com/GlueOps/registry/issues/8)): a patch to upstream's `registry/proxy`
  in `patches/`.

Stay as close to upstream as possible. Both fixes are written to be submitted upstream as-is.
Don't add features; raise them upstream.

## Why there is no go.mod

The ECR fix uses upstream's `internal/client/transport`, and Go only allows `internal/`
imports from inside the same module. So our `.go` files are compiled as upstream's
`cmd/registry` package (see the Dockerfile), and upstream's `go.mod`/`go.sum`/`vendor/`
pin all dependencies. A `go.mod` here would make the fix impossible without forking upstream.

Run the tests with `scripts/test.sh`: it checks out the pinned upstream into `.upstream/`
(git-ignored), applies `patches/`, copies our files in, and runs `gofmt`, `go vet` and
`go test -race` in the pinned Go image. Edit our files in the repo root, and the patch via
`.upstream/` (next section); `.upstream/` is reset on every run.

## The proxy patch

`patches/0001-proxy-serve-cache-when-upstream-unreachable.patch` is a `git diff` of
`registry/proxy` at the pinned commit, applied with `git apply` (no fuzz: a patch that
doesn't fit the pinned commit fails the build and `scripts/test.sh`). It changes three
source files, adds a test file, and adds two mock methods to upstream's
`proxymanifeststore_test.go`. To change it, run
`scripts/test.sh` once so `.upstream/` holds the patched tree, edit
`.upstream/registry/proxy/`, and save before the next run resets `.upstream/`:

```bash
git -C .upstream add -N registry/proxy
git -C .upstream diff -- registry/proxy > patches/0001-proxy-serve-cache-when-upstream-unreachable.patch
```

Scope the diff to `registry/proxy`: `.upstream/cmd/registry/` holds our copied files.
`scripts/test.sh` refuses to reset `.upstream/` while it holds edits the patch doesn't;
to discard them instead, `rm -rf .upstream`.
On a version bump, `scripts/test.sh` fails at `git apply` and leaves `.upstream/` at the new
commit. Run `git -C .upstream apply --reject "$PWD"/patches/*.patch`, fix the hunks in the
`.rej` files, delete the `.rej` files, regenerate.

The README says what the patch does; the `var` block at the top of `proxyregistry.go`
holds the numbers. The timeouts are package `var`s so the patch's own tests can shorten them.

## Invariants

- `main.go` is upstream's `cmd/registry/main.go` plus the line setting
  `transport.DefaultTransportWrapper`. Diff it against upstream on every version bump.
- Never modify `http.DefaultTransport` or `http.DefaultClient`. Upstream code type-asserts
  `http.DefaultTransport` (notifications, S3/Azure `skipverify`), and the AWS SDK uses
  `http.DefaultClient` for S3. The previous version of this repo broke both. Using them
  (`http.DefaultClient.Do`, as the patched `ping` does) is fine.
- The patch touches only `registry/proxy`. Timeouts and the failure memory live there;
  `transport.go` stays ECR-only.
- Only a network failure marks the upstream down (`upstreamUnreachable`), never an HTTP
  status. `*url.Error` implements `net.Error`, so a bare `net.Error` check would count a
  token-server 401 as an outage.
- The ping and the single-tag lookup run on contexts the client can't cancel, bounded by
  their timeouts, so a client that hangs up early neither counts as an outage nor keeps
  one from being noticed. Listings (`All`/`List`) are not bounded and record nothing: a
  big repository can legitimately take longer than one lookup.
- The failure memory only decides whether to ask the upstream before serving a cached tag.
  It never turns a miss into a 404 without asking; cold fetches by digest are unchanged.
- A successful tag lookup or ping clears the failure memory. Fetches by digest record
  nothing either way. When the memory expires during an outage, one tag lookup probes and
  the rest keep serving the cache until it reports (`skipUpstream`). Listings never probe
  (`upstreamDown`): they record nothing, so a probe they claimed would never be released.
- Nothing is installed at build time: the patch is applied in a stage built from the
  digest-pinned `GO_TEST_IMAGE`, which has git.
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
| Go images (must match upstream's `GO_VERSION`/`ALPINE_VERSION`) | `Dockerfile` (build stage, and `GO_TEST_IMAGE` for the patch stage and `scripts/test.sh`) |
| Base image `registry:X.Y.Z` (must match the commit) | `Dockerfile` |
| Actions (SHA + release comment), buildx, BuildKit, runner `ubuntu-26.04` | `.github/workflows/` |
| The patch | `patches/` must apply to the commit; `scripts/test.sh` and the build fail otherwise |

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
- `registry/proxy/proxyupstream_test.go` (in the patch): the patched proxy against a fake
  token-auth upstream that can stop answering. Covers a restart during an outage, shared
  pings, cache-first while down, misses still asking, recovery, a caller hanging up, HTTP
  errors, and the error classifier.
- `scripts/test.sh` runs `./cmd/registry/` and `./registry/proxy/` with `-race`; CI runs
  the same script. The Docker build also runs them (without cgo).
- `scripts/e2e-outage.sh IMAGE [CONTROL_IMAGE]`: blackholes the upstream from a built
  image in a throwaway network namespace (docker only, `NET_ADMIN`) and times cached pulls
  before and after a restart, with concurrency, and recovery. Run it before merging a
  change to the patch and on every version bump; pass the previous release as the control.
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
- PRs are squash- or rebase-merged: keep the PR title identical to the commit subject, and
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

When upstream fixes #4383 and #3033 (or merges the patch), switch to stock `registry` and
archive this. If only one lands, drop that fix and keep the other.
