#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 IMAGE BASE_DIGEST DEPENDENCY_FINGERPRINT" >&2
    exit 2
fi

IMAGE=$1
BASE_DIGEST=$2
DEPENDENCY_FINGERPRINT=$3

docker run --rm "$IMAGE" /bin/sh -euxc '
    ! command -v go
    ! test -e /usr/local/go
    ! env | grep -Eq "^(GOROOT|GOPATH|GOTOOLCHAIN)="
    ! command -v mise

    for command in bash git curl wget ssh scp sftp tar gzip bzip2 xz unzip zstd file patch jq ps make pkg-config gcc g++ \
        i686-linux-gnu-gcc i686-linux-gnu-g++ \
        aarch64-linux-gnu-gcc aarch64-linux-gnu-g++ \
        arm-linux-gnueabihf-gcc arm-linux-gnueabihf-g++ \
        powerpc64le-linux-gnu-gcc powerpc64le-linux-gnu-g++; do
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

    printf "%s\n" "#include <stdio.h>" "int main(void) { puts(\"ok\"); return 0; }" >"$work/native.c"
    gcc "$work/native.c" -o "$work/native-c"
    test "$("$work/native-c")" = ok

    printf "%s\n" "#include <iostream>" "int main() { std::cout << \"ok\"; }" >"$work/native.cpp"
    g++ "$work/native.cpp" -o "$work/native-cpp"
    test "$("$work/native-cpp")" = ok

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

    gcc "$work/pam-crypt.c" -o "$work/native-pam-crypt" -lpam -lcrypt
    "$work/native-pam-crypt"

    build_cross() {
        compiler=$1
        expected=$2
        output="$work/$compiler"
        "$compiler" "$work/pam-crypt.c" -o "$output" -lpam -lcrypt
        file "$output" | grep -E "$expected"
    }

    build_cross i686-linux-gnu-gcc "ELF 32-bit LSB.*Intel 80386"
    build_cross aarch64-linux-gnu-gcc "ELF 64-bit LSB.*ARM aarch64"
    build_cross arm-linux-gnueabihf-gcc "ELF 32-bit LSB.*ARM"
    build_cross powerpc64le-linux-gnu-gcc "ELF 64-bit LSB.*PowerPC"

    printf "%s\n" "int main() { return 0; }" >"$work/cross.cpp"
    i686-linux-gnu-g++ "$work/cross.cpp" -o "$work/i686-cpp"
    aarch64-linux-gnu-g++ "$work/cross.cpp" -o "$work/aarch64-cpp"
    arm-linux-gnueabihf-g++ "$work/cross.cpp" -o "$work/armhf-cpp"
    powerpc64le-linux-gnu-g++ "$work/cross.cpp" -o "$work/ppc64le-cpp"

    for package in \
        libpam0g-dev:i386 libcrypt-dev:i386 \
        libpam0g-dev:arm64 libcrypt-dev:arm64 \
        libpam0g-dev:armhf libcrypt-dev:armhf \
        libpam0g-dev:ppc64el libcrypt-dev:ppc64el; do
        test "$(dpkg-query -W -f="\${db:Status-Status}" "$package")" = installed
    done
'

labels=$(docker image inspect "$IMAGE" --format '{{json .Config.Labels}}')
test "$(printf '%s' "$labels" | jq -r '."org.opencontainers.image.base.name"')" = "docker.io/library/debian:bookworm-slim"
test "$(printf '%s' "$labels" | jq -r '."org.opencontainers.image.base.digest"')" = "$BASE_DIGEST"
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.dependency-fingerprint"')" = "$DEPENDENCY_FINGERPRINT"
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.distribution"')" = "debian12"
test "$(printf '%s' "$labels" | jq -r '."org.engity.build-images.purpose"')" = "build-toolbox"
test "$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')" = "linux/amd64"
