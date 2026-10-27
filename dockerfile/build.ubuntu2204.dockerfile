# 3FS build environment for Ubuntu 22.04 (matches the production nodes).
#
# This image only contains the toolchain and dependencies. The source tree is
# bind-mounted at build time (needs .git + submodules for version info), and
# binaries land in <repo>/build/bin on the host.
#
#   docker build -f dockerfile/build.ubuntu2204.dockerfile -t 3fs-build:ubuntu22.04 dockerfile/
#   docker run --rm -v "$PWD":/src 3fs-build:ubuntu22.04 /src/dockerfile/build-3fs.sh
#
# Build-time network notes: GitHub is unreliable from some networks, so the
# FoundationDB client deb and the libfuse tarball are NOT downloaded here; put
# them in dockerfile/deps/ first (see below). Rust uses the rsproxy.cn mirror.

FROM ubuntu:22.04

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive

# Optional apt mirror, e.g. --build-arg APT_MIRROR=http://mirrors.aliyun.com/ubuntu
ARG APT_MIRROR=
RUN if [ -n "${APT_MIRROR}" ]; then \
      sed -i "s|http://archive.ubuntu.com/ubuntu|${APT_MIRROR}|g; s|http://security.ubuntu.com/ubuntu|${APT_MIRROR}|g" /etc/apt/sources.list; \
    fi

# Package list = dockerfile/dev.dockerfile + packages needed by third_party
# builds (jemalloc autogen, folly, arrow, ibverbs link) that dev.dockerfile
# relies on the CI runner image to provide.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git pkg-config perl python3 python3-dev xz-utils \
      build-essential gcc-12 g++-12 cmake meson ninja-build autoconf automake libtool \
      clang-14 clang-format-14 clang-tidy-14 lld-14 \
      google-perftools libgoogle-perftools-dev \
      libaio-dev libboost-all-dev libdouble-conversion-dev libdwarf-dev \
      libgflags-dev libgmock-dev libgoogle-glog-dev libgtest-dev \
      liblz4-dev liblzma-dev libssl-dev libunwind-dev libuv1-dev \
      zlib1g-dev libbz2-dev libevent-dev libibverbs-dev librdmacm-dev libnuma-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# FoundationDB client (libfdb_c + headers). Must match your FDB server version
# (3FS uses API version 710). Pre-download into dockerfile/deps/ (see below);
# GitHub is unreliable from some networks, so the build does not fetch it.
#   mkdir -p dockerfile/deps && cd dockerfile/deps
#   wget -c https://github.com/apple/foundationdb/releases/download/7.3.63/foundationdb-clients_7.3.63-1_amd64.deb
#   wget -c -O fuse-3.16.2.tgz https://codeload.github.com/libfuse/libfuse/tar.gz/refs/tags/fuse-3.16.2
ARG FDB_VERSION=7.3.63
COPY deps/foundationdb-clients_${FDB_VERSION}-1_amd64.deb /tmp/fdb.deb
RUN dpkg -i /tmp/fdb.deb && rm /tmp/fdb.deb

# libfuse >= 3.16.1 is required; Ubuntu 22.04 ships 3.10.5.
# Built STATIC on purpose: the host already has libfuse3.so.3 (3.10.5) in the
# system path, and a mismatched shared copy at runtime is a trap. A static
# libfuse3.a is linked into hf3fs_fuse_main so nothing needs installing on nodes.
ARG LIBFUSE_VERSION=3.16.2
COPY deps/fuse-${LIBFUSE_VERSION}.tgz /tmp/libfuse.tgz
RUN mkdir /tmp/libfuse \
    && tar -xzf /tmp/libfuse.tgz --strip-components=1 -C /tmp/libfuse && rm /tmp/libfuse.tgz \
    && cd /tmp/libfuse && mkdir build && cd build \
    && meson setup .. --prefix=/usr/local -Ddefault_library=static -Dexamples=false -Dtests=false -Dutils=false \
    && ninja && ninja install \
    && rm -rf /tmp/libfuse
ENV PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig

# Rust: repo requires >= 1.75, MSRV in Cargo.toml is 1.85.
ARG RUST_VERSION=1.85.0
# static.rust-lang.org is very slow/unstable from some networks, so use the
# rsproxy.cn mirror by default (it hosts rustup-init, toolchains and the
# crates.io sparse index). Set RUST_MIRROR=https://static.rust-lang.org and
# CRATES_INDEX=sparse+https://index.crates.io/ to use the upstream instead.
ARG RUST_MIRROR=https://rsproxy.cn
ARG CRATES_INDEX=sparse+https://rsproxy.cn/index/
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:${PATH}
ENV RUSTUP_DIST_SERVER=${RUST_MIRROR} RUSTUP_UPDATE_ROOT=${RUST_MIRROR}/rustup
RUN curl -fsSL --retry 5 --retry-all-errors -o /tmp/rustup-init \
      ${RUST_MIRROR}/rustup/dist/x86_64-unknown-linux-gnu/rustup-init \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain ${RUST_VERSION} \
    && rm /tmp/rustup-init \
    && printf '[source.crates-io]\nreplace-with = "mirror"\n[source.mirror]\nregistry = "%s"\n' "${CRATES_INDEX}" > /opt/cargo/config.toml \
    && rustc --version && cargo --version

# Source is a bind mount owned by another uid; let git (used by GitVersion.cmake) read it.
RUN git config --global --add safe.directory '*'

WORKDIR /src
