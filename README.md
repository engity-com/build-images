# Build images

This repository publishes the build toolbox image `ghcr.io/engity-com/build-images/build` for `linux/amd64`. It uses Debian 12 as its distribution and glibc ABI baseline.

## Usage

The tags `debian12` and `latest` identify the same OCI image. Consumers should pin the distribution tag and digest rather than use the moving alias alone:

```text
ghcr.io/engity-com/build-images/build:debian12@sha256:<digest>
```

The image supplies shell, Git, SSH, download and archive tools, native C/C++ build dependencies, PAM and crypt development files, and cross-compilers for i386, ARM64, ARM hard-float, and little-endian PowerPC64. It deliberately does not include Go, Mise, or another language runtime. Consumer repositories install their pinned languages and project tools with Mise.

## Updates

A daily workflow resolves the concrete `linux/amd64` manifest behind `debian:bookworm-slim` and simulates Debian upgrades plus the package allowlist. It combines that result with all build inputs in a dependency fingerprint. An unchanged fingerprint causes the build and publication to be skipped. Pull requests always build and test locally but cannot publish. Published images carry these labels:

| Label | Meaning |
| --- | --- |
| `org.opencontainers.image.base.name` | Tracked Debian base tag |
| `org.opencontainers.image.base.digest` | Concrete AMD64 base manifest |
| `org.engity.build-images.dependency-fingerprint` | Effective dependency state |
| `org.engity.build-images.distribution` | Stable distribution line |
| `org.engity.build-images.purpose` | Image role |

The legacy `ghcr.io/engity-com/build-images/go:*` tags are frozen. Existing tags and digest references remain available, but they are no longer updated.
