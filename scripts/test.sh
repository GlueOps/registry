#!/usr/bin/env bash
# Run the tests the way the image build does, plus -race.
#
# This repo has no go.mod on purpose: the fix uses upstream's internal/ package,
# which only code inside upstream's module may import. So the tests run inside a
# checkout of the pinned upstream commit, in .upstream/ (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."

commit=$(sed -n 's/^ARG DISTRIBUTION_COMMIT=//p' Dockerfile)
go_image=$(sed -n 's/^ARG GO_TEST_IMAGE=//p' Dockerfile)

if [[ "$(git -C .upstream rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
  rm -rf .upstream
  git init -q .upstream
  git -C .upstream fetch -q --depth 1 https://github.com/distribution/distribution.git "$commit"
  git -C .upstream checkout -q FETCH_HEAD
fi
# Start from the pristine commit every time, so stale files never get tested.
git -C .upstream reset -q --hard
git -C .upstream clean -fdq
cp ./*.go .upstream/cmd/registry/

docker run --rm -e GOTOOLCHAIN=local -v "$PWD/.upstream:/src" -w /src "$go_image" sh -c '
  unformatted=$(gofmt -l cmd/registry)
  if [ -n "$unformatted" ]; then echo "gofmt needed: $unformatted" >&2; exit 1; fi
  go vet ./cmd/registry/ && go test -race -count=1 "$@" ./cmd/registry/' -- "$@"
