#!/bin/sh
set -eu

ARCHITECTURES="i386 arm64 armhf ppc64el"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PACKAGES_FILE="$SCRIPT_DIR/packages.txt"

apt_get() {
    apt-get \
        -o Acquire::Retries=5 \
        -o Acquire::http::Timeout=30 \
        -o Acquire::https::Timeout=30 \
        "$@"
}

packages() {
    awk 'NF && $1 !~ /^#/ { print $1 }' "$PACKAGES_FILE"
}

add_architectures() {
    for architecture in $ARCHITECTURES; do
        dpkg --add-architecture "$architecture"
    done
}

install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    add_architectures
    apt_get update
    apt_get upgrade -y
    # Intentional word splitting turns the canonical newline-separated list into apt arguments.
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

validate_installed_state() {
    state_file=${DEPENDENCY_STATE_FILE:-/build-input/dependency-state.txt}
    if [ ! -r "$state_file" ]; then
        echo "dependency state is not readable: $state_file" >&2
        exit 1
    fi

    expected_file=$(mktemp)
    awk '
        $0 == "[final-packages]" { packages = 1; next }
        packages && /^\[/ { exit }
        packages && NF { print }
    ' "$state_file" >"$expected_file"

    if [ ! -s "$expected_file" ]; then
        echo "dependency state contains no package records" >&2
        rm -f "$expected_file"
        exit 1
    fi

    validation_error=
    while IFS='|' read -r package_name architecture version; do
        if [ -z "$package_name" ] || [ -z "$architecture" ] || [ -z "$version" ]; then
            validation_error="invalid package record in dependency state"
            break
        fi
        :
    done <"$expected_file"

    installed_raw=$(dpkg-query -W -f='${binary:Package}|${Architecture}|${Version}\n')
    installed_file=$(mktemp)
    printf '%s\n' "$installed_raw" | awk -F '|' '
        {
            sub(/:.*/, "", $1)
            print $1 "|" $2 "|" $3
        }
    ' | LC_ALL=C sort -u >"$installed_file"
    if ! cmp -s "$expected_file" "$installed_file"; then
        validation_error="installed package state differs from the resolved dependency state"
        diff -u "$expected_file" "$installed_file" >&2 || true
    fi
    rm -f "$expected_file"
    rm -f "$installed_file"
    if [ -n "$validation_error" ]; then
        echo "$validation_error" >&2
        exit 1
    fi
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
    export DEBIAN_FRONTEND=noninteractive
    export LC_ALL=C

    add_architectures
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

    initial_raw=$(dpkg-query -W -f='${binary:Package}|${Architecture}|${Version}\n')
    initial_packages=$(printf '%s\n' "$initial_raw" | awk -F '|' '
        {
            sub(/:.*/, "", $1)
            print $1 "|" $2 "|" $3
        }
    ')
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

validate_digest() {
    value=${1#sha256:}
    if [ "$value" = "$1" ] || [ "${#value}" -ne 64 ]; then
        echo "invalid sha256 digest: $1" >&2
        exit 1
    fi
    case "$value" in
        *[!0-9a-f]*)
            echo "invalid sha256 digest: $1" >&2
            exit 1
            ;;
        *) ;;
    esac
}

base_reference() {
    if [ "$#" -ne 1 ]; then
        echo "usage: $0 base-reference IMAGE:TAG" >&2
        exit 2
    fi

    image=$1
    repository=${image%:*}
    raw=$(docker buildx imagetools inspect --raw "$image")
    digest=$(printf '%s' "$raw" | jq -er '
        if (.mediaType | test("image.index|manifest.list")) then
            [.manifests[] | select(
                .platform.os == "linux" and
                .platform.architecture == "amd64" and
                ((.platform.variant // "") == "")
            )] |
            if length == 1 then .[0].digest
            else error("expected exactly one linux/amd64 manifest")
            end
        else
            error("base tag does not reference an OCI index")
        end
    ')
    validate_digest "$digest"
    docker buildx imagetools inspect "$repository@$digest" >/dev/null
    printf '%s@%s\n' "$repository" "$digest"
}

fingerprint_state() {
    if [ "$#" -ne 1 ]; then
        echo "usage: $0 fingerprint-state IMAGE@SHA256" >&2
        exit 2
    fi

    base_image=$1
    base_digest=${base_image##*@}
    validate_digest "$base_digest"

    resolution=$(docker run \
        --platform linux/amd64 \
        --rm \
        --mount "type=bind,source=$SCRIPT_DIR,target=/build-input,readonly" \
        --entrypoint /bin/sh \
        "$base_image" \
        /build-input/dependencies.sh resolve)

    printf '%s\n' \
        'format=1' \
        "base_digest=$base_digest" \
        "dockerfile_sha256=$(sha256sum "$SCRIPT_DIR/Dockerfile" | awk '{ print $1 }')" \
        "packages_sha256=$(sha256sum "$PACKAGES_FILE" | awk '{ print $1 }')" \
        "dependencies_sha256=$(sha256sum "$SCRIPT_DIR/dependencies.sh" | awk '{ print $1 }')" \
        "dockerignore_sha256=$(sha256sum "$SCRIPT_DIR/.dockerignore" | awk '{ print $1 }')" \
        "architectures=$ARCHITECTURES" \
        "$resolution"
}

dependency_fingerprint() {
    state=$(fingerprint_state "$@")
    digest=$(printf '%s\n' "$state" | sha256sum | awk '{ print $1 }')
    validate_digest "sha256:$digest"
    printf 'sha256:%s\n' "$digest"
}

prepare_dependency_state() {
    if [ "$#" -ne 2 ]; then
        echo "usage: $0 prepare IMAGE@SHA256 OUTPUT" >&2
        exit 2
    fi

    output=$2
    state=$(fingerprint_state "$1")
    printf '%s\n' "$state" >"$output"
    digest=$(sha256sum "$output" | awk '{ print $1 }')
    validate_digest "sha256:$digest"
    printf 'sha256:%s\n' "$digest"
}

remote_image_state() {
    if [ "$#" -ne 1 ]; then
        echo "usage: $0 remote-image-state IMAGE:TAG" >&2
        exit 2
    fi

    if [ -z "${GHCR_USERNAME:-}" ] || [ -z "${GHCR_TOKEN:-}" ]; then
        echo "GHCR_USERNAME and GHCR_TOKEN are required" >&2
        exit 2
    fi

    image=$1
    registry=${image%%/*}
    remainder=${image#*/}
    repository=${remainder%:*}
    tag=${image##*:}
    if [ "$registry" != "ghcr.io" ] || [ -z "$repository" ] || [ "$tag" = "$image" ]; then
        echo "unsupported GHCR image reference: $image" >&2
        exit 2
    fi

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT HUP INT TERM
    token_status=$(curl --silent --show-error \
        --user "$GHCR_USERNAME:$GHCR_TOKEN" \
        --output "$work/token.json" \
        --write-out '%{http_code}' \
        "https://ghcr.io/token?service=ghcr.io&scope=repository:$repository:pull")
    if [ "$token_status" != 200 ]; then
        echo "GHCR token service returned HTTP $token_status" >&2
        exit 1
    fi
    bearer=$(jq -er '.token' "$work/token.json")

    manifest_status=$(curl --silent --show-error \
        --header "Authorization: Bearer $bearer" \
        --header 'Accept: application/vnd.oci.image.index.v1+json' \
        --header 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        --output "$work/index.json" \
        --write-out '%{http_code}' \
        "https://ghcr.io/v2/$repository/manifests/$tag")
    case "$manifest_status" in
        200) ;;
        404)
            if jq -e '
                .errors | length > 0 and
                all(.code == "MANIFEST_UNKNOWN" or .code == "NAME_UNKNOWN")
            ' "$work/index.json" >/dev/null; then
                printf '%s\n' 'status=missing'
                return
            fi
            echo "GHCR returned an ambiguous HTTP 404" >&2
            exit 1
            ;;
        *)
            echo "GHCR manifest request returned HTTP $manifest_status" >&2
            exit 1
            ;;
    esac

    index_digest=sha256:$(sha256sum "$work/index.json" | awk '{ print $1 }')
    validate_digest "$index_digest"

    digest=$(jq -er '
        if (.mediaType | test("image.index|manifest.list")) then
            [.manifests[] | select(
                .platform.os == "linux" and
                .platform.architecture == "amd64" and
                ((.platform.variant // "") == "")
            )] |
            if length == 1 then .[0].digest
            else error("expected exactly one linux/amd64 runtime manifest")
            end
        else
            error("published tag does not reference an OCI index")
        end
    ' "$work/index.json")
    validate_digest "$digest"

    status=$(curl --silent --show-error --location \
        --header "Authorization: Bearer $bearer" \
        --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
        --header 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        --output "$work/manifest.json" \
        --write-out '%{http_code}' \
        "https://ghcr.io/v2/$repository/manifests/$digest")
    if [ "$status" != 200 ]; then
        echo "GHCR runtime manifest request returned HTTP $status" >&2
        exit 1
    fi
    actual_digest=sha256:$(sha256sum "$work/manifest.json" | awk '{ print $1 }')
    if [ "$actual_digest" != "$digest" ]; then
        echo "GHCR runtime manifest digest mismatch" >&2
        exit 1
    fi
    config_digest=$(jq -er '.config.digest' "$work/manifest.json")
    validate_digest "$config_digest"

    status=$(curl --silent --show-error --location \
        --header "Authorization: Bearer $bearer" \
        --output "$work/config.json" \
        --write-out '%{http_code}' \
        "https://ghcr.io/v2/$repository/blobs/$config_digest")
    if [ "$status" != 200 ]; then
        echo "GHCR image config request returned HTTP $status" >&2
        exit 1
    fi
    actual_digest=sha256:$(sha256sum "$work/config.json" | awk '{ print $1 }')
    if [ "$actual_digest" != "$config_digest" ]; then
        echo "GHCR image config digest mismatch" >&2
        exit 1
    fi

    fingerprint=$(jq -er '.config.Labels."org.engity.build-images.dependency-fingerprint" // "unlabeled"' "$work/config.json")
    base_digest=$(jq -r '.config.Labels."org.opencontainers.image.base.digest" // "unknown"' "$work/config.json")
    if [ "$fingerprint" != "unlabeled" ]; then
        validate_digest "$fingerprint"
        validate_digest "$base_digest"
        jq -e '
            .config.Labels."org.opencontainers.image.base.name" == "docker.io/library/debian:bookworm-slim" and
            .config.Labels."org.engity.build-images.distribution" == "debian12" and
            .config.Labels."org.engity.build-images.purpose" == "build-toolbox"
        ' "$work/config.json" >/dev/null

        attestation_digests=$(jq -er --arg runtime "$digest" '
            [.manifests[] | select(
                .platform.os == "unknown" and
                .platform.architecture == "unknown" and
                .annotations."vnd.docker.reference.type" == "attestation-manifest" and
                .annotations."vnd.docker.reference.digest" == $runtime
            )] as $attestations |
            if ($attestations | length) >= 1 and
               (.manifests | length) == (($attestations | length) + 1)
            then $attestations[].digest
            else error("invalid or unrelated attestation manifests")
            end
        ' "$work/index.json")

        predicates=
        for attestation_digest in $attestation_digests; do
            validate_digest "$attestation_digest"
            status=$(curl --silent --show-error --location \
                --header "Authorization: Bearer $bearer" \
                --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
                --output "$work/attestation.json" \
                --write-out '%{http_code}' \
                "https://ghcr.io/v2/$repository/manifests/$attestation_digest")
            if [ "$status" != 200 ]; then
                echo "GHCR attestation manifest request returned HTTP $status" >&2
                exit 1
            fi
            actual_digest=sha256:$(sha256sum "$work/attestation.json" | awk '{ print $1 }')
            if [ "$actual_digest" != "$attestation_digest" ]; then
                echo "GHCR attestation manifest digest mismatch" >&2
                exit 1
            fi
            predicates="$predicates
$(jq -r '.layers[].annotations."in-toto.io/predicate-type" // empty' "$work/attestation.json")"
        done
        printf '%s\n' "$predicates" | grep -q 'https://slsa.dev/provenance/'
        printf '%s\n' "$predicates" | grep -q 'https://spdx.dev/Document'
    fi
    printf 'status=present\nfingerprint=%s\nbase_digest=%s\nindex_digest=%s\n' "$fingerprint" "$base_digest" "$index_digest"
}

build_decision() {
    if [ "$#" -ne 4 ]; then
        echo "usage: $0 decision CURRENT EXPECTED FORCE TAGS_MATCH" >&2
        exit 2
    fi

    current=$1
    expected=$2
    force=$3
    tags_match=$4
    promote=false
    validate_digest "$expected"
    if [ "$current" != missing ] && [ "$current" != unlabeled ]; then
        validate_digest "$current"
    fi

    case "$force" in
        true)
            build=true
            reason=forced
            ;;
        false)
            if [ "$current" = "$expected" ] && [ "$tags_match" = true ]; then
                build=false
                reason=unchanged
            elif [ "$current" = missing ]; then
                build=true
                reason=bootstrap
            elif [ "$current" = unlabeled ]; then
                build=true
                reason=migration
            elif [ "$current" = "$expected" ]; then
                build=false
                promote=true
                reason=tags-diverged
            else
                build=true
                reason=dependencies-changed
            fi
            ;;
        *)
            echo "force must be true or false" >&2
            exit 2
            ;;
    esac
    if [ "$tags_match" != true ] && [ "$tags_match" != false ]; then
        echo "tags_match must be true or false" >&2
        exit 2
    fi
    printf 'build=%s\npromote=%s\nreason=%s\n' "$build" "$promote" "$reason"
}

test_decision() {
    one=sha256:1111111111111111111111111111111111111111111111111111111111111111
    two=sha256:2222222222222222222222222222222222222222222222222222222222222222
    test "$(build_decision "$one" "$one" false true)" = "$(printf 'build=false\npromote=false\nreason=unchanged')"
    test "$(build_decision missing "$one" false false)" = "$(printf 'build=true\npromote=false\nreason=bootstrap')"
    test "$(build_decision unlabeled "$one" false true)" = "$(printf 'build=true\npromote=false\nreason=migration')"
    test "$(build_decision "$two" "$one" false true)" = "$(printf 'build=true\npromote=false\nreason=dependencies-changed')"
    test "$(build_decision "$one" "$one" false false)" = "$(printf 'build=false\npromote=true\nreason=tags-diverged')"
    test "$(build_decision "$one" "$one" true true)" = "$(printf 'build=true\npromote=false\nreason=forced')"
}

case "${1:-}" in
    install)
        shift
        install_dependencies "$@"
        ;;
    resolve)
        shift
        resolve_dependencies "$@"
        ;;
    base-reference)
        shift
        base_reference "$@"
        ;;
    fingerprint-state)
        shift
        fingerprint_state "$@"
        ;;
    fingerprint)
        shift
        dependency_fingerprint "$@"
        ;;
    prepare)
        shift
        prepare_dependency_state "$@"
        ;;
    remote-image-state)
        shift
        remote_image_state "$@"
        ;;
    decision)
        shift
        build_decision "$@"
        ;;
    test-decision)
        shift
        test_decision "$@"
        ;;
    *)
        echo "usage: $0 {install|resolve|base-reference|fingerprint-state|fingerprint|prepare|remote-image-state|decision|test-decision}" >&2
        exit 2
        ;;
esac
