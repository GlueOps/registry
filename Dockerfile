# Upstream Distribution with one change: the ECR blob HEAD fallback. See AGENTS.md.

# Matches upstream's GO_VERSION / ALPINE_VERSION at the pinned release.
FROM --platform=$BUILDPLATFORM golang:1.25.9-alpine3.23@sha256:5caaf1cca9dc351e13deafbc3879fd4754801acba8653fa9540cea125d01a71f AS build
ARG DISTRIBUTION_COMMIT=9a8d98b679740cd514aa7e7d84d23d442a5ef54c
# Same Go on glibc, for -race (needs cgo); used by scripts/test.sh.
ARG GO_TEST_IMAGE=golang:1.25.9-trixie@sha256:e31c2b19d37ddc2a558bafa599ec54a11443affd0623f653d23b75ab28022a90

ADD --keep-git-dir=false https://github.com/distribution/distribution.git#${DISTRIBUTION_COMMIT} /src
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local

COPY *.go cmd/registry/
# Before the platform ARGs, so the tests run once rather than per target.
RUN go test ./cmd/registry/

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
