# Upstream Distribution with two fixes: the ECR blob HEAD fallback (transport.go)
# and the unreachable-upstream patch (patches/). See AGENTS.md.

ARG DISTRIBUTION_COMMIT=9a8d98b679740cd514aa7e7d84d23d442a5ef54c
# Same Go on glibc, for -race (needs cgo); used by scripts/test.sh. It has git,
# so it also applies the patch: the alpine image has neither git nor patch.
ARG GO_TEST_IMAGE=golang:1.27.3-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80

FROM --platform=$BUILDPLATFORM ${GO_TEST_IMAGE} AS src
ARG DISTRIBUTION_COMMIT
ADD --keep-git-dir=false https://github.com/distribution/distribution.git#${DISTRIBUTION_COMMIT} /src
COPY patches/ /patches/
# git apply has no fuzz: a patch that no longer fits the pinned commit fails the build.
RUN cd /src && git apply /patches/*.patch

# Matches upstream's GO_VERSION / ALPINE_VERSION at the pinned release.
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.23@sha256:5d5113301ffcac84e2bfb20c42648803fecaea6789c89bb9b66884e18cbb30a7 AS build
COPY --from=src /src /src
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local

COPY *.go cmd/registry/
# Before the platform ARGs, so the tests run once rather than per target.
RUN go test ./cmd/registry/ ./registry/proxy/

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=3.1.1+glueops.dev
ARG REVISION=unknown
# -X must name the package that declares the variables (upstream's version
# package); the values identify this repo's build.
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath \
      -ldflags "-s -w \
        -X github.com/distribution/distribution/v3/version.mainpkg=github.com/GlueOps/registry \
        -X github.com/distribution/distribution/v3/version.version=${VERSION} \
        -X github.com/distribution/distribution/v3/version.revision=${REVISION}" \
      -o /registry ./cmd/registry

FROM registry:3.1.1@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0
COPY --from=build /registry /bin/registry
