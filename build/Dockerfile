# syntax=docker/dockerfile:1
ARG BASE_IMAGE=docker.io/library/debian:bookworm-slim
FROM ${BASE_IMAGE}

ARG BASE_IMAGE_DIGEST
ARG DEPENDENCY_FINGERPRINT

LABEL org.opencontainers.image.base.name="docker.io/library/debian:bookworm-slim" \
      org.opencontainers.image.base.digest="${BASE_IMAGE_DIGEST}" \
      org.engity.build-images.dependency-fingerprint="${DEPENDENCY_FINGERPRINT}" \
      org.engity.build-images.distribution="debian12" \
      org.engity.build-images.purpose="build-toolbox"

RUN --mount=type=bind,source=packages.txt,target=/build-input/packages.txt,readonly \
    --mount=type=bind,source=dependencies.sh,target=/build-input/dependencies.sh,readonly \
    --mount=type=bind,source=dependency-state.txt,target=/build-input/dependency-state.txt,readonly \
    test -n "${DEPENDENCY_FINGERPRINT}" && \
    /bin/sh /build-input/dependencies.sh install
