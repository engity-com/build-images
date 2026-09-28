#!/bin/sh
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 IMAGE BASE_DIGEST DEPENDENCY_FINGERPRINT TARGET" >&2
    exit 2
fi

IMAGE=$1
BASE_DIGEST=$2
DEPENDENCY_FINGERPRINT=$3
TARGET=$4

docker run --platform linux/amd64 --rm --env "TARGET=$TARGET" "$IMAGE" /bin/sh -euxc '
    ! command -v go
    ! test -e /usr/local/go
    ! env | grep -Eq "^(GOROOT|GOPATH|GOTOOLCHAIN)="
    ! command -v mise

    for command in bash git curl wget ssh scp sftp tar gzip bzip2 xz unzip zstd file patch jq ps make pkg-config; do
        command -v "$command"
    done
    curl --fail --silent --show-error --location --output /dev/null https://github.com/
    wget --quiet --spider https://github.com/

    ! find /var/lib/apt/lists -type f -print -quit | grep -q .
    ! find /var/cache/apt/archives -name "*.deb" -print -quit | grep -q .
    ! find /tmp /var/tmp -mindepth 1 -print -quit | grep -q .
    ! find /var/log/apt -type f -print -quit | grep -q .
    ! dpkg-query -W -f="\${db:Status-Abbrev}\n" libpam-doc 2>/dev/null | grep -q "^ii"

    work=$(mktemp -d)
    trap "rm -rf \"$work\"" EXIT HUP INT TERM
    cat >"$work/pam-crypt.c" <<"EOF"
#include <crypt.h>
#include <security/pam_appl.h>

int main(void) {
    pam_handle_t *handle = 0;
    (void) crypt("build-images", "xx");
    (void) pam_start("build-images", "build-images", 0, &handle);
    return 0;
}
EOF
    printf "%s\n" "#include <iostream>" "int main() { std::cout << \"ok\"; }" >"$work/test.cpp"

    case "$TARGET" in
        amd64)
            test -z "$(dpkg --print-foreign-architectures)"
            compiler=gcc
            cxx=g++
            dev_arch=amd64
            expected="ELF 64-bit LSB.*x86-64"
            ;;
        386)
            test "$(dpkg --print-foreign-architectures)" = i386
            compiler=i686-linux-gnu-gcc
            cxx=i686-linux-gnu-g++
            dev_arch=i386
            expected="ELF 32-bit LSB.*Intel 80386"
            ;;
        armv7)
            test "$(dpkg --print-foreign-architectures)" = armhf
            compiler=arm-linux-gnueabihf-gcc
            cxx=arm-linux-gnueabihf-g++
            dev_arch=armhf
            expected="ELF 32-bit LSB.*ARM"
            ;;
        arm64)
            test "$(dpkg --print-foreign-architectures)" = arm64
            compiler=aarch64-linux-gnu-gcc
            cxx=aarch64-linux-gnu-g++
            dev_arch=arm64
            expected="ELF 64-bit LSB.*ARM aarch64"
            ;;
        *) exit 2 ;;
    esac

    command -v "$compiler"
    command -v "$cxx"
    test "$(dpkg-query -W -f="\${db:Status-Status}" "libpam0g-dev:$dev_arch")" = installed
    test "$(dpkg-query -W -f="\${db:Status-Status}" "libcrypt-dev:$dev_arch")" = installed
    "$compiler" "$@" "$work/pam-crypt.c" -o "$work/pam-crypt" -lpam -lcrypt
    "$cxx" "$@" "$work/test.cpp" -o "$work/test-cpp"
    file "$work/pam-crypt" | grep -E "$expected"
    file "$work/test-cpp" | grep -E "$expected"
    if [ "$TARGET" = amd64 ]; then
        "$work/pam-crypt"
        test "$("$work/test-cpp")" = ok
    else
        ! command -v gcc
        ! command -v g++
    fi
    if [ "$TARGET" = armv7 ]; then
        arm-linux-gnueabihf-readelf -A "$work/pam-crypt" | grep -q "Tag_CPU_arch: v7"
        arm-linux-gnueabihf-readelf -A "$work/pam-crypt" | grep -q "Tag_ABI_VFP_args: VFP registers"
    fi

    for other in i686-linux-gnu aarch64-linux-gnu arm-linux-gnueabi arm-linux-gnueabihf powerpc64le-linux-gnu riscv64-linux-gnu; do
        if [ "$compiler" != "$other-gcc" ]; then
            ! command -v "$other-gcc"
            ! command -v "$other-g++"
        fi
    done
'

labels=$(docker image inspect "$IMAGE" --format '{{json .Config.Labels}}')
test "$(printf '%s' "$labels" | jq -r '."org.opencontainers.image.base.name"')" = docker.io/library/debian:bookworm-slim
test "$(printf '%s' "$labels" | jq -r '."org.opencontainers.image.base.digest"')" = "$BASE_DIGEST"
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.dependency-fingerprint"')" = "$DEPENDENCY_FINGERPRINT"
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.distribution"')" = debian12
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.purpose"')" = build-toolbox
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.target"')" = "$TARGET"
test "$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')" = linux/amd64
