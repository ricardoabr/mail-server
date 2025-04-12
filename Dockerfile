# syntax=docker/dockerfile:1
# check=skip=FromPlatformFlagConstDisallowed,RedundantTargetPlatform

# *****************
# Base image for planner & builder
# *****************
FROM --platform=$BUILDPLATFORM rust:slim-bookworm AS base

ENV DEBIAN_FRONTEND="noninteractive" \
    BINSTALL_DISABLE_TELEMETRY=true \
    CARGO_TERM_COLOR=always \
    LANG=C.UTF-8 \
    TZ=UTC \
    TERM=xterm-256color
# With zig, we only need libclang and make
RUN \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/keep-cache && \
    apt-get update && \
    apt-get install -yq --no-install-recommends curl jq xz-utils make libclang-19-dev
# Install zig
RUN \
    ZIG_VERSION=0.13.0 && \
    [ ! -z "$ZIG_VERSION" ] && \
    curl --retry 5 -Ls "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-$(uname -m)-${ZIG_VERSION}.tar.xz" | tar -J -x -C /usr/local && \
    ln -s "/usr/local/zig-linux-$(uname -m)-${ZIG_VERSION}/zig" /usr/local/bin/zig
# Install cargo-binstall
RUN curl --retry 5 -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash
# Install cargo-chef & sccache & cargo-zigbuild
RUN cargo binstall --no-confirm cargo-chef sccache cargo-zigbuild

# *****************
# Planner
# *****************
FROM base AS planner
WORKDIR /app
COPY . .
# Generate recipe file
RUN cargo chef prepare --recipe-path recipe.json

# *****************
# Builder
# *****************
FROM base AS builder
WORKDIR /app
COPY --from=planner /app/recipe.json recipe.json
ARG TARGET
ARG BUILD_ENV
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Install toolchain and specify some env variables
RUN \
    rustup set profile minimal && \
    rustup target add ${TARGET} && \
    mkdir -p artifact && \
    touch /env-cargo && \
    if [ ! -z "${BUILD_ENV}" ]; then \
        echo "export ${BUILD_ENV}" >> /env-cargo; \
        echo "Setting up ${BUILD_ENV}"; \
    fi && \
    if [[ "${TARGET}" == *gnu ]]; then \
        echo "export FDB_ARCH=${TARGET%%-*}" >> /env-cargo; \
    fi
# Install FoundationDB
RUN \
    source /env-cargo && \
    if [ ! -z "${FDB_ARCH}" ]; then \
        curl --retry 5 -Lso /usr/lib/libfdb_c.so "$(curl --retry 5 -Ls 'https://api.github.com/repos/apple/foundationdb/releases' | jq --arg FDB_ARCH "$FDB_ARCH" -r '.[] | select(.prerelease == false) | .assets[] | select(.name | test("libfdb_c." + $FDB_ARCH + ".so")) | .browser_download_url' | head -n1)"; \
    fi
# Cargo-chef Cache layer
RUN \
    --mount=type=secret,id=ACTIONS_CACHE_URL,env=ACTIONS_CACHE_URL \
    --mount=type=secret,id=ACTIONS_RUNTIME_TOKEN,env=ACTIONS_RUNTIME_TOKEN \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    source /env-cargo && \
    if [ ! -z "${FDB_ARCH}" ]; then \
        RUSTFLAGS="-L /usr/lib" cargo chef cook --recipe-path recipe.json --zigbuild --release --target ${TARGET} -p mail-server --no-default-features --features "foundationdb elastic s3 redis enterprise"; \
    fi
RUN \
    --mount=type=secret,id=ACTIONS_CACHE_URL,env=ACTIONS_CACHE_URL \
    --mount=type=secret,id=ACTIONS_RUNTIME_TOKEN,env=ACTIONS_RUNTIME_TOKEN \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    source /env-cargo && \
    cargo chef cook --recipe-path recipe.json --zigbuild --release --target ${TARGET} -p mail-server --no-default-features --features "sqlite postgres mysql rocks elastic s3 redis azure enterprise" && \
    cargo chef cook --recipe-path recipe.json --zigbuild --release --target ${TARGET} -p stalwart-cli
# Copy the source code
COPY . .
ENV RUSTC_WRAPPER="sccache" \
    SCCACHE_GHA_ENABLED=true
# Build FoundationDB version
RUN \
    --mount=type=secret,id=ACTIONS_CACHE_URL,env=ACTIONS_CACHE_URL \
    --mount=type=secret,id=ACTIONS_RUNTIME_TOKEN,env=ACTIONS_RUNTIME_TOKEN \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    source /env-cargo && \
    if [ ! -z "${FDB_ARCH}" ]; then \
        RUSTFLAGS="-L /usr/lib" cargo zigbuild --release --target ${TARGET} -p mail-server --no-default-features --features "foundationdb elastic s3 redis enterprise"; \
        mv /app/target/${TARGET}/release/stalwart-mail /app/artifact/stalwart-mail-foundationdb; \
    fi
# Build generic version
RUN \
    --mount=type=secret,id=ACTIONS_CACHE_URL,env=ACTIONS_CACHE_URL \
    --mount=type=secret,id=ACTIONS_RUNTIME_TOKEN,env=ACTIONS_RUNTIME_TOKEN \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    source /env-cargo && \
    cargo zigbuild --release --target ${TARGET} -p mail-server --no-default-features --features "sqlite postgres mysql rocks elastic s3 redis azure enterprise" && \
    cargo zigbuild --release --target ${TARGET} -p stalwart-cli && \
    mv /app/target/${TARGET}/release/stalwart-mail /app/artifact/stalwart-mail && \
    mv /app/target/${TARGET}/release/stalwart-cli /app/artifact/stalwart-cli

# *****************
# Binary stage
# *****************
FROM scratch AS binaries
COPY --from=builder /app/artifact /

# *****************
# Runtime image for GNU targets
# *****************
FROM --platform=$TARGETPLATFORM docker.io/library/debian:bookworm-slim AS gnu
WORKDIR /opt/stalwart-mail
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -yq ca-certificates tzdata
COPY --from=builder /app/artifact/stalwart-mail /usr/local/bin
COPY --from=builder /app/artifact/stalwart-cli /usr/local/bin
COPY ./resources/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod -R 755 /usr/local/bin
CMD ["/usr/local/bin/stalwart-mail"]
VOLUME [ "/opt/stalwart-mail" ]
EXPOSE	443 25 110 587 465 143 993 995 4190 8080
ENTRYPOINT ["/bin/sh", "/usr/local/bin/entrypoint.sh"]

# *****************
# Runtime image for musl targets
# *****************
FROM --platform=$TARGETPLATFORM alpine AS musl
WORKDIR /opt/stalwart-mail
RUN apk add --update --no-cache ca-certificates tzdata && rm -rf /var/cache/apk/*
COPY --from=builder /app/artifact/stalwart-mail /usr/local/bin
COPY --from=builder /app/artifact/stalwart-cli /usr/local/bin
COPY ./resources/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod -R 755 /usr/local/bin
CMD ["/usr/local/bin/stalwart-mail"]
VOLUME [ "/opt/stalwart-mail" ]
EXPOSE	443 25 110 587 465 143 993 995 4190 8080
ENTRYPOINT ["/bin/sh", "/usr/local/bin/entrypoint.sh"]
