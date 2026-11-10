# Upstream Distribution with two fixes: the ECR blob HEAD fallback (transport.go)
# and the unreachable-upstream patch (patches/). See AGENTS.md.

ARG DISTRIBUTION_COMMIT=9a8d98b679740cd514aa7e7d84d23d442a5ef54c
# Same Go on glibc, for -race (needs cgo); used by scripts/test.sh. It has git,
# so it also applies the patch: the alpine image has neither git nor patch.
ARG GO_TEST_IMAGE=golang:1.26.11-trixie@sha256:fa340cb59ebeb1d53ac1cccfc334201d938fe5f3458003cccb767096d8e032b8

FROM --platform=$BUILDPLATFORM ${GO_TEST_IMAGE} AS src
ARG DISTRIBUTION_COMMIT
ADD --keep-git-dir=false https://github.com/distribution/distribution.git#${DISTRIBUTION_COMMIT} /src
COPY patches/ /patches/
# git apply has no fuzz: a patch that no longer fits the pinned commit fails the build.
RUN cd /src && git apply /patches/*.patch

# Matches upstream's GO_VERSION / ALPINE_VERSION at the pinned release.
FROM --platform=$BUILDPLATFORM golang:1.26.11-alpine3.23@sha256:db99415e2625ce0ee03eed09edf7f32ae8c58dc399f28cc602a87fe7238119e4 AS build
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
