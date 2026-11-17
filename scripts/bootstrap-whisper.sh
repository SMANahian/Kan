#!/usr/bin/env bash
#
# Builds the whisper.cpp static libraries that the CWhisper target links (see Package.swift).
#
# Usage: scripts/bootstrap-whisper.sh [--force] [--check] [--keep-build] [--jobs N]
#
#   (no flags)    build only when Vendor/whisper/lib is missing or doesn't match Vendor/whisper/VERSION
#   --force       rebuild even when everything is up to date
#   --check       only report: exit 0 when up to date, 1 when a build is needed
#   --keep-build  keep the CMake build directory (Vendor/whisper.cpp/build-kan)
#   --jobs N      parallel compile jobs (default: all cores)
#
# Steps:
#   1. Shallow-clone ggml-org/whisper.cpp at the pinned tag into Vendor/whisper.cpp and verify the
#      commit (a moved upstream tag is refused, never built).
#   2. Static Release build with the flags verified on this toolchain: Metal with the shader library
#      embedded (compiled at runtime, so neither Xcode nor the `metal` compiler is needed),
#      Accelerate + Apple BLAS, generic Apple Silicon code (GGML_NATIVE=OFF), no OpenMP (no libomp
#      dylib to ship), arm64 only, macOS 14.0 deployment target.
#   3. Install the six archives into Vendor/whisper/lib, whisper.h plus the ggml headers it includes
#      into Sources/CWhisper/include (module.modulemap is kept), and write Vendor/whisper/VERSION.
#   4. Record checksums and the flag fingerprint in Vendor/whisper/lib/BUILD-INFO; later runs skip
#      the build while they still match.
#
# Needs git, cmake (Homebrew or MacPorts) and the Xcode Command Line Tools; uses Ninja if installed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "$ROOT/scripts/lib/common.sh"

TAG="v1.9.5"
COMMIT="d1be6fde11ac6e0407606b4e42fe72d34add8037"
REPO_URL="https://github.com/ggml-org/whisper.cpp.git"

SRC="$ROOT/Vendor/whisper.cpp"
BUILD="$SRC/build-kan"
VENDOR_DIR="$ROOT/Vendor/whisper"
LIB_DIR="$VENDOR_DIR/lib"
INCLUDE_DIR="$ROOT/Sources/CWhisper/include"
VERSION_FILE="$VENDOR_DIR/VERSION"
BUILD_INFO="$LIB_DIR/BUILD-INFO"
LOCK="$ROOT/.build/bootstrap-whisper.lock"

# Archive name and where CMake puts it, relative to the build directory.
LIBS=(libwhisper.a libggml.a libggml-base.a libggml-cpu.a libggml-blas.a libggml-metal.a)
LIB_BUILD_PATHS=(
  src/libwhisper.a
  ggml/src/libggml.a
  ggml/src/libggml-base.a
  ggml/src/libggml-cpu.a
  ggml/src/ggml-blas/libggml-blas.a
  ggml/src/ggml-metal/libggml-metal.a
)
# Header name and its path in the source tree.
HEADERS=(whisper.h ggml.h ggml-cpu.h ggml-backend.h ggml-alloc.h)
HEADER_SRC_PATHS=(
  include/whisper.h
  ggml/include/ggml.h
  ggml/include/ggml-cpu.h
  ggml/include/ggml-backend.h
  ggml/include/ggml-alloc.h
)

DEPLOYMENT_TARGET="14.0"
# Changing anything here changes the fingerprint in BUILD-INFO, which triggers a rebuild.
CMAKE_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_ACCELERATE=ON
  -DGGML_BLAS=ON
  -DGGML_BLAS_VENDOR=Apple
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DGGML_CCACHE=OFF
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET"
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DWHISPER_BUILD_TESTS=OFF
  -DWHISPER_BUILD_EXAMPLES=OFF
  -DWHISPER_BUILD_SERVER=OFF
  -DWHISPER_SDL2=OFF
  -DWHISPER_CURL=OFF
  -DWHISPER_COREML=OFF
)

FORCE=0
CHECK_ONLY=0
KEEP_BUILD=0
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
    --keep-build) KEEP_BUILD=1 ;;
    --jobs)
      [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive number"
      JOBS="$2"
      shift
      ;;
    -h | --help) print_usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

flags_fingerprint() { printf '%s\n' "${CMAKE_FLAGS[@]}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'; }

# What BUILD-INFO must contain (minus '#' comment lines) for the installed files to count as built
# from $TAG with $CMAKE_FLAGS. Missing files hash as "missing".
expected_build_info() {
  local i path
  printf 'tag %s\ncommit %s\nflags %s\n' "$TAG" "$COMMIT" "$(flags_fingerprint)"
  for i in "${!LIBS[@]}"; do
    path="$LIB_DIR/${LIBS[$i]}"
    if [[ -f "$path" ]]; then printf 'sha256 %s lib/%s\n' "$(sha256_of "$path")" "${LIBS[$i]}"
    else printf 'sha256 missing lib/%s\n' "${LIBS[$i]}"; fi
  done
  for i in "${!HEADERS[@]}"; do
    path="$INCLUDE_DIR/${HEADERS[$i]}"
    if [[ -f "$path" ]]; then printf 'sha256 %s include/%s\n' "$(sha256_of "$path")" "${HEADERS[$i]}"
    else printf 'sha256 missing include/%s\n' "${HEADERS[$i]}"; fi
  done
}

# Sets STALE_REASON and returns 1 when a build is needed.
STALE_REASON=""
is_up_to_date() {
  local name
  if [[ ! -f "$VERSION_FILE" || "$(head -n 1 "$VERSION_FILE")" != "$TAG $COMMIT" ]]; then
    STALE_REASON="Vendor/whisper/VERSION is missing or names another version"
    return 1
  fi
  for name in "${LIBS[@]}"; do
    [[ -f "$LIB_DIR/$name" ]] || { STALE_REASON="Vendor/whisper/lib/$name is missing"; return 1; }
  done
  for name in "${HEADERS[@]}" module.modulemap; do
    [[ -f "$INCLUDE_DIR/$name" ]] || { STALE_REASON="Sources/CWhisper/include/$name is missing"; return 1; }
  done
  if [[ ! -f "$BUILD_INFO" ]]; then
    STALE_REASON="no build record (Vendor/whisper/lib/BUILD-INFO); the libraries weren't built by this script"
    return 1
  fi
  if [[ "$(grep -v '^#' "$BUILD_INFO")" != "$(expected_build_info)" ]]; then
    STALE_REASON="the libraries or headers differ from the recorded build, or the build flags changed"
    return 1
  fi
  return 0
}

ensure_source() {
  local head=""
  if [[ -d "$SRC/.git" ]]; then
    head="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$head" != "$COMMIT" ]]; then
      step "Vendor/whisper.cpp is at ${head:-an unknown commit}; replacing it with $TAG"
      rm -rf "${SRC:?}"
    fi
  elif [[ -e "$SRC" ]]; then
    die "$SRC exists but isn't a git checkout. Move it away and run again."
  fi

  if [[ ! -d "$SRC" ]]; then
    step "Cloning whisper.cpp $TAG (shallow)"
    rm -rf "${SRC:?}.partial"
    # init + fetch of just the tag: `clone --branch <annotated tag>` works too but warns that the
    # tag "is not a commit".
    if ! { git init --quiet "$SRC.partial" &&
      git -C "$SRC.partial" remote add origin "$REPO_URL" &&
      git -C "$SRC.partial" fetch --quiet --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG" &&
      git -C "$SRC.partial" -c advice.detachedHead=false checkout --quiet "refs/tags/$TAG"; }; then
      rm -rf "${SRC:?}.partial"
      die "could not fetch whisper.cpp $TAG from $REPO_URL (offline?)"
    fi
    mv "$SRC.partial" "$SRC"
  fi

  head="$(git -C "$SRC" rev-parse HEAD)"
  [[ "$head" == "$COMMIT" ]] ||
    die "whisper.cpp $TAG resolved to $head, expected $COMMIT. The upstream tag may have moved; not building unverified sources."
  if [[ -n "$(git -C "$SRC" status --porcelain --untracked-files=no)" ]]; then
    die "Vendor/whisper.cpp has local modifications. Discard them (git -C Vendor/whisper.cpp checkout -- .) or remove the directory."
  fi
  ok "whisper.cpp $TAG at $COMMIT"
}

configure_and_build() {
  local generator=()
  if command -v ninja >/dev/null 2>&1; then generator=(-G Ninja); fi
  # Apple's compilers and archivers explicitly (see apple_tool in lib/common.sh).
  local toolchain=(
    "-DCMAKE_C_COMPILER=$CLANG"
    "-DCMAKE_CXX_COMPILER=$CLANGXX"
    "-DCMAKE_AR=$AR"
    "-DCMAKE_RANLIB=$RANLIB"
    "-DCMAKE_OSX_SYSROOT=$SDK_PATH"
  )

  step "Configuring (static Release, Metal embedded, Accelerate/BLAS, arm64, macOS $DEPLOYMENT_TARGET)"
  rm -rf "${BUILD:?}"
  # Compiler flags from the environment (a conda env's CFLAGS, say) must not leak into the build.
  /usr/bin/env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u OBJCFLAGS -u LDFLAGS -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET \
    cmake -S "$SRC" -B "$BUILD" ${generator[@]+"${generator[@]}"} "${toolchain[@]}" "${CMAKE_FLAGS[@]}" \
    > "$BUILD.configure.log" 2>&1 || { tail -n 40 "$BUILD.configure.log" >&2; die "CMake configure failed (full log: $BUILD.configure.log)"; }
  rm -f "$BUILD.configure.log"

  step "Compiling with $JOBS jobs"
  /usr/bin/env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u OBJCFLAGS -u LDFLAGS \
    cmake --build "$BUILD" --config Release --target whisper --parallel "$JOBS"
}

# Checks that an archive is arm64-only and built for the deployment target.
verify_archive() {
  local lib="$1" archs minos
  archs="$("$LIPO" -archs "$lib" 2>/dev/null || true)"
  [[ "$archs" == "arm64" ]] || die "$(basename "$lib") has architectures '$archs', expected arm64"
  minos="$("$OTOOL" -l "$lib" | /usr/bin/awk '/LC_BUILD_VERSION/ { f = 1 } f && $1 == "minos" { print $2; f = 0 }' | sort -u | tr '\n' ' ')"
  [[ "$minos" == "$DEPLOYMENT_TARGET " ]] ||
    die "$(basename "$lib") targets macOS '${minos% }', expected $DEPLOYMENT_TARGET"
}

install_outputs() {
  local staging="$VENDOR_DIR/lib.new.$$" previous="$VENDOR_DIR/lib.old.$$" i built header

  step "Installing libraries and headers"
  rm -rf "${staging:?}"
  mkdir -p "$staging" "$INCLUDE_DIR"
  for i in "${!LIBS[@]}"; do
    built="$BUILD/${LIB_BUILD_PATHS[$i]}"
    [[ -f "$built" ]] || die "the build did not produce ${LIB_BUILD_PATHS[$i]}"
    verify_archive "$built"
    cp "$built" "$staging/${LIBS[$i]}"
  done

  for i in "${!HEADERS[@]}"; do
    header="$SRC/${HEADER_SRC_PATHS[$i]}"
    [[ -f "$header" ]] || die "whisper.cpp has no ${HEADER_SRC_PATHS[$i]}"
    cp "$header" "$INCLUDE_DIR/${HEADERS[$i]}.tmp.$$"
    mv "$INCLUDE_DIR/${HEADERS[$i]}.tmp.$$" "$INCLUDE_DIR/${HEADERS[$i]}"
  done
  if [[ ! -f "$INCLUDE_DIR/module.modulemap" ]]; then
    warn "Sources/CWhisper/include/module.modulemap was missing; writing the standard one"
    printf 'module CWhisper {\n    header "whisper.h"\n    export *\n}\n' > "$INCLUDE_DIR/module.modulemap"
  fi

  # Swap the whole directory so a reader (a concurrent swift build) never sees a mix of old and new.
  if [[ -d "$LIB_DIR" ]]; then mv "$LIB_DIR" "$previous"; fi
  mv "$staging" "$LIB_DIR"
  rm -rf "${previous:?}"

  printf '%s %s\n' "$TAG" "$COMMIT" > "$VERSION_FILE"
  {
    expected_build_info
    printf '# built %s by scripts/bootstrap-whisper.sh (macOS %s, %s)\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sw_vers -productVersion)" "$(cmake --version | head -n 1)"
  } > "$BUILD_INFO.tmp"
  mv "$BUILD_INFO.tmp" "$BUILD_INFO"
}

print_summary() {
  local name
  for name in "${LIBS[@]}"; do
    info "$(printf '%-18s %10s' "$name" "$(human_bytes "$(file_size "$LIB_DIR/$name")")")"
  done
}

# ------------------------------------------------------------------------------------------------

if [[ "$CHECK_ONLY" == 1 ]]; then
  if is_up_to_date; then ok "whisper.cpp $TAG static libraries are up to date"; exit 0; fi
  echo "whisper.cpp needs a build: $STALE_REASON"
  exit 1
fi

if [[ "$FORCE" == 0 ]] && is_up_to_date; then
  ok "whisper.cpp $TAG static libraries are up to date (Vendor/whisper/lib); use --force to rebuild"
  exit 0
fi
[[ "$FORCE" == 1 ]] || info "building because $STALE_REASON"

require_cmd git "Install the Xcode Command Line Tools: xcode-select --install"
require_cmd cmake "Install CMake, e.g. 'brew install cmake' or 'sudo port install cmake'."
# Resolved up front: a failing $(...) inside an array literal would not stop the script.
CLANG="$(apple_tool clang)"
CLANGXX="$(apple_tool clang++)"
AR="$(apple_tool ar)"
RANLIB="$(apple_tool ranlib)"
LIPO="$(apple_tool lipo)"
OTOOL="$(apple_tool otool)"
SDK_PATH="$(/usr/bin/xcrun --show-sdk-path)"
[[ "$(uname -m)" == "arm64" ]] || warn "this shell runs as $(uname -m); Kan only builds for Apple Silicon (arm64)"

mkdir -p "$ROOT/.build"
acquire_lock "$LOCK"
trap 'release_lock "$LOCK"; rm -rf "${VENDOR_DIR:?}"/lib.new.* "${SRC:?}.partial"' EXIT

START=$SECONDS
ensure_source
configure_and_build
install_outputs
if [[ "$KEEP_BUILD" == 0 ]]; then rm -rf "${BUILD:?}"; fi

step "whisper.cpp $TAG ready in $((SECONDS - START)) s"
print_summary
info "headers in Sources/CWhisper/include: ${HEADERS[*]}"
