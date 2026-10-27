#!/bin/bash
# Build 3FS inside the 3fs-build image. See build.ubuntu2204.dockerfile.
#
#   SHUFFLE_METHOD  g++10 | g++11 | stdshuffle   (default g++11). Fixed per cluster:
#                   never change it after the first deployment.
#   JOBS            parallel jobs (default: nproc)
#   RETRIES         retries of the build step (default 3). Arrow's bundled
#                   dependencies are downloaded from GitHub at build time and
#                   can fail transiently; re-running resumes the build.
set -euo pipefail

SRC="${SRC:-/src}"
cd "$SRC"

# A failed build must not leave a previous success marker available for packaging.
rm -f build/bin/BUILD_INFO

: "${SHUFFLE_METHOD:=g++11}"
: "${JOBS:=$(nproc)}"
: "${RETRIES:=3}"

./patches/apply.sh

cmake -S . -B build \
  -DCMAKE_CXX_COMPILER=clang++-14 -DCMAKE_C_COMPILER=clang-14 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DSHUFFLE_METHOD="${SHUFFLE_METHOD}"

for i in $(seq 1 "${RETRIES}"); do
  if cmake --build build -j "${JOBS}"; then
    break
  fi
  [ "$i" -eq "${RETRIES}" ] && { echo "build failed after ${RETRIES} attempts" >&2; exit 1; }
  echo "build attempt $i failed, retrying..." >&2
  sleep 10
done

{
  echo "commit=$(git rev-parse HEAD)"
  echo "shuffle_method=${SHUFFLE_METHOD}"
  git submodule status
} > build/bin/BUILD_INFO.tmp
mv build/bin/BUILD_INFO.tmp build/bin/BUILD_INFO

echo "---- missing shared libs (run this on a target node too) ----"
for b in build/bin/*; do
  [ -x "$b" ] && ldd "$b" 2>/dev/null | grep "not found" | sed "s|^|$(basename "$b"): |" || true
done
ls -la build/bin
