#!/usr/bin/env bash
# Run the tests the way the image build does, plus -race.
#
# This repo has no go.mod on purpose: the fixes use upstream's internal/ package,
# which only code inside upstream's module may import. So the tests run inside a
# checkout of the pinned upstream commit, in .upstream/ (git-ignored), with
# patches/ applied and our files copied into cmd/registry.
set -euo pipefail
cd "$(dirname "$0")/.."

commit=$(sed -n 's/^ARG DISTRIBUTION_COMMIT=//p' Dockerfile)
go_image=$(sed -n 's/^ARG GO_TEST_IMAGE=//p' Dockerfile)

# .upstream is reset below. Refuse if it holds edits that patches/ doesn't (see AGENTS.md):
# reverse-apply the patches, in reverse order, and require a clean tree.
if git -C .upstream rev-parse -q --verify HEAD >/dev/null 2>&1; then
  git -C .upstream reset -q   # drop intent-to-add entries left by regenerating the patch
  mapfile -t reversed < <(printf '%s\n' "$PWD"/patches/*.patch | sort -r)
  if [[ -n "$(git -C .upstream status --porcelain -- registry/proxy)" ]] \
     && { ! git -C .upstream apply -R "${reversed[@]}" \
          || [[ -n "$(git -C .upstream status --porcelain -- registry/proxy)" ]]; }; then
    for p in "$PWD"/patches/*.patch; do git -C .upstream apply "$p" 2>/dev/null || true; done   # leave it as found
    echo "error: .upstream/registry/proxy has edits not in patches/; regenerate the patch or discard them" >&2
    exit 1
  fi
fi
if [[ "$(git -C .upstream rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
  rm -rf .upstream
  git init -q .upstream
  git -C .upstream fetch -q --depth 1 https://github.com/distribution/distribution.git "$commit"
  git -C .upstream checkout -q FETCH_HEAD
fi
# Start from the pristine commit every time, so stale files never get tested.
git -C .upstream reset -q --hard
git -C .upstream clean -fdq
git -C .upstream apply "$PWD"/patches/*.patch
cp ./*.go .upstream/cmd/registry/

docker run --rm -e GOTOOLCHAIN=local -v "$PWD/.upstream:/src" -w /src "$go_image" sh -c '
  unformatted=$(gofmt -l cmd/registry registry/proxy)
  if [ -n "$unformatted" ]; then echo "gofmt needed: $unformatted" >&2; exit 1; fi
  go vet ./cmd/registry/ ./registry/proxy/ && go test -race -count=1 "$@" ./cmd/registry/ ./registry/proxy/' -- "$@"
