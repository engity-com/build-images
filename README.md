# Build images

This repository publishes the build toolbox image `ghcr.io/engity-com/build-images/build` for `linux/amd64`. It uses Debian 12 as its distribution and glibc ABI baseline.

## Usage

The tags `debian12` and `latest` identify the same OCI image. Consumers should pin the distribution tag and digest rather than use the moving alias alone:

```text
ghcr.io/engity-com/build-images/build:debian12@sha256:<digest>
```

The image supplies shell, Git, SSH, download and archive tools, native C/C++ build dependencies, PAM and crypt development files, and cross-compilers for i386, ARM64, ARM hard-float, and little-endian PowerPC64. It deliberately does not include Go, Mise, or another language runtime. Consumer repositories install their pinned languages and project tools with Mise.

## Target-specific images

For builds that need only one toolchain, the following additional tags provide separate `linux/amd64` build containers:

| Tag | C/C++ toolchain | PAM and crypt development libraries |
| --- | --- | --- |
| `debian12-386` | `i686-linux-gnu-gcc` / `g++` | `i386` |
| `debian12-amd64` | native `gcc` / `g++` | `amd64` |
| `debian12-armv7` | `arm-linux-gnueabihf-gcc` / `g++` | Debian `armhf` |
| `debian12-arm64` | `aarch64-linux-gnu-gcc` / `g++` | Debian `arm64` |

These are build-host images, **not** images that run on the target architecture. They retain the common shell, Git, SSH, download and archive tools but exclude other C/C++ toolchains and their development libraries. The original `debian12` and `latest` tags remain the full toolbox. Pin a target tag together with its OCI index digest, for example `ghcr.io/engity-com/build-images/build:debian12-armv7@sha256:<digest>`.

ARMv6 and RISC-V 64 are not published as Debian 12 target images: Bookworm's `armel` toolchain can build ARMv6 soft-float binaries, but its `armel` PAM dependencies cannot be installed alongside the current AMD64 security updates due to a multiarch `libssl3` version conflict. Bookworm provides RISC-V cross-compilers, but not the RISC-V PAM and crypt development packages needed for equivalent CGO builds. Mixing releases or downgrading the host's security packages is not used as a workaround.

## Updates

A daily workflow resolves the concrete `linux/amd64` manifest behind `debian:bookworm-slim` and simulates Debian upgrades plus the package allowlist. It combines that result with all build inputs in a dependency fingerprint. An unchanged fingerprint causes the build and publication to be skipped. Pull requests always build and test locally but cannot publish.

The target-specific images have independent package lists and fingerprints. A separate daily workflow checks each target and publishes only the changed tags after local C/C++ and PAM/crypt link tests. Every published tag includes provenance and an SBOM. Published images carry these labels:

| Label | Meaning |
| --- | --- |
| `org.opencontainers.image.base.name` | Tracked Debian base tag |
| `org.opencontainers.image.base.digest` | Concrete AMD64 base manifest |
| `org.engity.build-images.dependency-fingerprint` | Effective dependency state |
| `org.engity.build-images.distribution` | Stable distribution line |
| `org.engity.build-images.purpose` | Image role |
| `org.engity.build-images.target` | Target architecture (target-specific images only) |

The legacy `ghcr.io/engity-com/build-images/go:*` tags are frozen. Existing tags and digest references remain available, but they are no longer updated.
