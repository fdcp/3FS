#!/usr/bin/env bash
# Package the built 3FS binaries into a self-contained tarball that can be
# copied to other Ubuntu 22.04 nodes and installed with the bundled install.sh.
#
# Run on the build host AFTER dockerfile/build-3fs.sh succeeded:
#   dockerfile/package-3fs.sh
#
# Env:
#   OUT_DIR   where to write the result            (default: ./dist)
#   STRIP     1 = strip debug info (much smaller, but stack traces lose
#             symbols)                              (default: 0)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT}/build/bin"
JEMALLOC_DIR="${ROOT}/build/third_party/jemalloc/lib"
DEPS_DIR="${ROOT}/dockerfile/deps"
OUT_DIR="${OUT_DIR:-${ROOT}/dist}"
STRIP="${STRIP:-0}"

[ -f "${BIN_DIR}/BUILD_INFO" ] || { echo "missing ${BIN_DIR}/BUILD_INFO: build first" >&2; exit 1; }
[ -f "${JEMALLOC_DIR}/libjemalloc.so.2" ] || { echo "missing libjemalloc.so.2 under ${JEMALLOC_DIR}" >&2; exit 1; }
FDB_DEB="$(ls "${DEPS_DIR}"/foundationdb-clients_*_amd64.deb 2>/dev/null | head -1 || true)"
[ -n "${FDB_DEB}" ] || { echo "missing foundationdb-clients deb under ${DEPS_DIR}" >&2; exit 1; }

COMMIT="$(sed -n 's/^commit=//p' "${BIN_DIR}/BUILD_INFO" | cut -c1-8)"
NAME="3fs-${COMMIT}-ubuntu2204"
STAGE="${OUT_DIR}/${NAME}"

rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/lib" "${STAGE}/deps" "${STAGE}/configs"

# Binaries only (skip anything non-executable except BUILD_INFO).
for f in "${BIN_DIR}"/*; do
  if [ -x "$f" ] && [ -f "$f" ]; then
    cp "$f" "${STAGE}/bin/"
  fi
done
cp "${BIN_DIR}/BUILD_INFO" "${STAGE}/"
if [ "${STRIP}" = "1" ]; then
  echo "stripping binaries..."
  strip --strip-debug "${STAGE}"/bin/* 
fi

# The binaries carry RUNPATH=/src/build/third_party/jemalloc/lib (the path
# inside the build container), so ship the library and register it via ldconfig.
cp -a "${JEMALLOC_DIR}/libjemalloc.so.2" "${STAGE}/lib/"

cp "${FDB_DEB}" "${STAGE}/deps/"
cp "${ROOT}"/configs/*.toml "${STAGE}/configs/"

cat > "${STAGE}/install.sh" <<'EOF'
#!/usr/bin/env bash
# Install 3FS binaries and runtime dependencies on an Ubuntu 22.04 node.
# Usage: sudo ./install.sh [PREFIX]      (default PREFIX=/opt/3fs)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${1:-/opt/3fs}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
. /etc/os-release
if [ "${ID}" != "ubuntu" ] || [ "${VERSION_ID}" != "22.04" ]; then
  echo "WARNING: built for Ubuntu 22.04, this node is ${PRETTY_NAME}" >&2
fi

# Runtime libraries (package names resolved from the build image).
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  libboost-context1.74.0 libboost-filesystem1.74.0 libboost-program-options1.74.0 \
  libboost-regex1.74.0 libboost-system1.74.0 libboost-thread1.74.0 libboost-atomic1.74.0 \
  libdouble-conversion3 libgflags2.2 libgoogle-glog0v5 libevent-2.1-7 \
  libdwarf1 libgoogle-perftools4 libatomic1 libaio1 libibverbs1 libnuma1

# FoundationDB client library (must match the FDB server cluster version).
dpkg -i "${HERE}"/deps/foundationdb-clients_*_amd64.deb

mkdir -p "${PREFIX}/bin" "${PREFIX}/lib" "${PREFIX}/configs"
cp -a "${HERE}"/bin/* "${PREFIX}/bin/"
cp -a "${HERE}"/lib/* "${PREFIX}/lib/"
cp -n "${HERE}"/configs/*.toml "${PREFIX}/configs/"   # never overwrite existing configs
cp "${HERE}/BUILD_INFO" "${PREFIX}/"

# jemalloc: binaries look for it via a RUNPATH that only exists in the build container.
echo "${PREFIX}/lib" > /etc/ld.so.conf.d/3fs.conf
ldconfig

echo "---- missing shared libs (should be empty) ----"
missing=0
for b in "${PREFIX}"/bin/*; do
  out="$(ldd "$b" 2>/dev/null | grep 'not found' || true)"
  if [ -n "$out" ]; then echo "$(basename "$b"):"; echo "$out"; missing=1; fi
done
if [ "$missing" -ne 0 ]; then
  echo "installation incomplete: missing shared libraries" >&2
  exit 1
fi
echo "ok: all dependencies resolved"
echo "installed to ${PREFIX}"
EOF
chmod +x "${STAGE}/install.sh"

echo "creating ${OUT_DIR}/${NAME}.tar.gz ..."
tar -C "${OUT_DIR}" -czf "${OUT_DIR}/${NAME}.tar.gz" "${NAME}"
ls -lh "${OUT_DIR}/${NAME}.tar.gz"
echo "staging dir: ${STAGE}"
