# syntax=docker/dockerfile:1
ARG GO_VERSION=latest
FROM golang:${GO_VERSION}

RUN    dpkg --add-architecture i386 \
    && dpkg --add-architecture arm64 \
    && dpkg --add-architecture armel \
    && dpkg --add-architecture armhf \
    && dpkg --add-architecture ppc64el \
    && dpkg --add-architecture s390x \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y \
        gcc \
        g++ \
        libpam0g-dev \
        libcrypt-dev \
        \
        gcc-i686-linux-gnu \
        g++-i686-linux-gnu \
        libpam0g-dev:i386 \
        libcrypt-dev:i386 \
        \
        gcc-aarch64-linux-gnu \
        g++-aarch64-linux-gnu \
        libpam0g-dev:arm64 \
        libcrypt-dev:arm64 \
        \
        gcc-arm-linux-gnueabi \
        g++-arm-linux-gnueabi \
        libpam0g-dev:armel \
        libcrypt-dev:armel \
        \
        gcc-arm-linux-gnueabihf \
        g++-arm-linux-gnueabihf \
        libpam0g-dev:armhf \
        libcrypt-dev:armhf \
        \
        gcc-powerpc64le-linux-gnu \
        g++-powerpc64le-linux-gnu \
        libpam0g-dev:ppc64el \
        libcrypt-dev:ppc64el \
        \
        gcc-s390x-linux-gnu \
        g++-s390x-linux-gnu \
        libpam0g-dev:s390x \
        libcrypt-dev:s390x \
    && apt-get clean \
    && rm -rf \
        /tmp/* \
        /var/cache/* \
        /var/lib/apt/lists/* \
        /var/log/*.log \
        /var/log/apt
