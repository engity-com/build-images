#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

configure_target() {
    case "${TARGET:-}" in
        amd64) ARCHITECTURE= ;;
        386) ARCHITECTURE=i386 ;;
        armv7) ARCHITECTURE=armhf ;;
        arm64) ARCHITECTURE=arm64 ;;
        *) echo "unsupported target: ${TARGET:-}" >&2; exit 2 ;;
    esac
}

apt_get() {
    apt-get \
        -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        "$@"
}

packages() {
    awk 'NF && $1 !~ /^#/ { print $1 }' \
        "$SCRIPT_DIR/packages/common.txt" "$SCRIPT_DIR/packages/$TARGET.txt"
}

add_architecture() {
    if [ -n "$ARCHITECTURE" ]; then
        dpkg --add-architecture "$ARCHITECTURE"
    fi
}

installed_packages() {
    dpkg-query -W -f='${binary:Package}|${Architecture}|${Version}\n' | awk -F '|' '
        {
            sub(/:.*/, "", $1)
            print $1 "|" $2 "|" $3
        }
    '
}

validate_installed_state() {
    state_file=${DEPENDENCY_STATE_FILE:-/build-input/dependency-state.txt}
    if [ ! -r "$state_file" ]; then
        echo "dependency state is not readable: $state_file" >&2
        exit 1
    fi

    expected_file=$(mktemp)
    installed_file=$(mktemp)
    awk '
        $0 == "[final-packages]" { packages = 1; next }
        packages && /^\[/ { exit }
        packages && NF { print }
    ' "$state_file" >"$expected_file"
    if [ ! -s "$expected_file" ]; then
        echo "dependency state contains no package records" >&2
        exit 1
    fi
    installed_packages | LC_ALL=C sort -u >"$installed_file"
    if ! cmp -s "$expected_file" "$installed_file"; then
        diff -u "$expected_file" "$installed_file" >&2 || true
        echo "installed package state differs from the resolved dependency state" >&2
        exit 1
    fi
    rm -f "$expected_file" "$installed_file"
}

install_dependencies() {
    configure_target
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    add_architecture
    apt_get update
    apt_get upgrade -y
    # The canonical package list is passed to apt as separate arguments.
    # shellcheck disable=SC2046
    apt_get install -y --no-install-recommends $(packages)
    validate_installed_state
    apt-get clean
    rm -rf \
        /tmp/* \
        /var/tmp/* \
        /var/cache/apt/archives/*.deb \
        /var/lib/apt/lists/* \
        /var/log/*.log \
        /var/log/apt/*
}

parse_package_records() {
    awk '
        $1 == "Inst" {
            package_name = $2
            if (package_name ~ /:/) {
                architecture = package_name
                sub(/^.*:/, "", architecture)
            } else {
                architecture = $0
                sub(/^.*\[/, "", architecture)
                sub(/\].*$/, "", architecture)
            }
            sub(/:.*/, "", package_name)
            version = $0
            sub(/^.*\(/, "", version)
            sub(/ .*/, "", version)
            if (architecture == $0 || version == $0 || package_name == "") {
                exit 1
            }
            print package_name "|" architecture "|" version
        }
    '
}

resolve_dependencies() {
    configure_target
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    add_architecture
    apt_get update >&2
    upgrade_output=$(apt_get --simulate upgrade)
    # shellcheck disable=SC2046
    install_output=$(apt_get --simulate install --no-install-recommends $(packages))
    upgrade_unsorted=$(printf '%s\n' "$upgrade_output" | parse_package_records)
    install_unsorted=$(printf '%s\n' "$install_output" | parse_package_records)
    upgrade_changes=$(printf '%s\n' "$upgrade_unsorted" | LC_ALL=C sort -u)
    install_changes=$(printf '%s\n' "$install_unsorted" | LC_ALL=C sort -u)
    records_unsorted=$(printf '%s\n%s\n' "$upgrade_output" "$install_output" | parse_package_records)
    records=$(printf '%s\n' "$records_unsorted" | LC_ALL=C sort -u)

    if printf '%s\n%s\n' "$upgrade_output" "$install_output" | awk '$1 == "Remv" { found = 1 } END { exit !found }'; then
        echo "apt resolution unexpectedly removes packages" >&2
        exit 1
    fi

    initial_packages=$(installed_packages)
    final_packages=$(printf '%s\n%s\n' "$initial_packages" "$records" | awk -F '|' '
        NF == 3 { packages[$1 "|" $2] = $3 }
        END {
            for (package_name in packages) {
                print package_name "|" packages[package_name]
            }
        }
    ' | LC_ALL=C sort -u)
    if [ -z "$install_changes" ] || [ -z "$records" ]; then
        echo "apt resolution produced no package changes" >&2
        exit 1
    fi

    printf '%s\n' '[upgrade]'
    if [ -n "$upgrade_changes" ]; then
        printf '%s\n' "$upgrade_changes" | awk '{ print "upgrade|" $0 }'
    else
        printf '%s\n' 'none'
    fi
    printf '%s\n' '[install]'
    printf '%s\n' "$install_changes" | awk '{ print "install|" $0 }'
    printf '%s\n' '[packages]'
    printf '%s\n' "$records"
    printf '%s\n' '[final-packages]'
    printf '%s\n' "$final_packages"
}

fingerprint_state() {
    configure_target
    base_image=$1
    base_digest=${base_image##*@}
    digest_value=${base_digest#sha256:}
    if [ "$digest_value" = "$base_digest" ] || [ "${#digest_value}" -ne 64 ]; then
        echo "invalid base digest: $base_digest" >&2
        exit 1
    fi
    case "$digest_value" in
        *[!0-9a-f]*) echo "invalid base digest: $base_digest" >&2; exit 1 ;;
    esac

    resolution=$(docker run \
        --platform linux/amd64 \
        --rm \
        --env "TARGET=$TARGET" \
        --mount "type=bind,source=$SCRIPT_DIR,target=/build-input,readonly" \
        --entrypoint /bin/sh \
        "$base_image" \
        /build-input/dependencies.sh resolve)

    printf '%s\n' \
        'format=1' \
        "target=$TARGET" \
        "base_digest=$base_digest" \
        "dockerfile_sha256=$(sha256sum "$SCRIPT_DIR/Dockerfile" | awk '{ print $1 }')" \
        "common_sha256=$(sha256sum "$SCRIPT_DIR/packages/common.txt" | awk '{ print $1 }')" \
        "packages_sha256=$(sha256sum "$SCRIPT_DIR/packages/$TARGET.txt" | awk '{ print $1 }')" \
        "dependencies_sha256=$(sha256sum "$SCRIPT_DIR/dependencies.sh" | awk '{ print $1 }')" \
        "dockerignore_sha256=$(sha256sum "$SCRIPT_DIR/.dockerignore" | awk '{ print $1 }')" \
        "architecture=$ARCHITECTURE" \
        "$resolution"
}

prepare_dependency_state() {
    if [ "$#" -ne 3 ]; then
        echo "usage: $0 prepare IMAGE@SHA256 TARGET OUTPUT" >&2
        exit 2
    fi
    TARGET=$2
    output=$3
    fingerprint_state "$1" >"$output"
    digest=$(sha256sum "$output" | awk '{ print $1 }')
    printf 'sha256:%s\n' "$digest"
}

case "${1:-}" in
    install) shift; install_dependencies "$@" ;;
    resolve) shift; resolve_dependencies "$@" ;;
    prepare) shift; prepare_dependency_state "$@" ;;
    *) echo "usage: $0 {install|resolve|prepare}" >&2; exit 2 ;;
esac
