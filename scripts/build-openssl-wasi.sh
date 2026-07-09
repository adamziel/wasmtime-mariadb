#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${OPENSSL_SOURCE:-$root/third_party/openssl}"
build_dir="${OPENSSL_WASI_BUILD_DIR:-$root/build/openssl-wasi}"
install_dir="$build_dir/install"
image="${WASI_SDK_IMAGE:-ghcr.io/webassembly/wasi-sdk:wasi-sdk-33}"
patch_file="$root/patches/openssl-wasi/0001-wasi-disable-issetugid-probe.patch"
log_file="${OPENSSL_WASI_BUILD_LOG:-$build_dir/build.log}"

if [[ ! -f "$source_dir/Configure" ]]; then
  OPENSSL_SOURCE="$source_dir" "$root/scripts/fetch-openssl-source.sh"
fi

mkdir -p "$build_dir"
docker run --rm \
  -v "$build_dir:/build:z" \
  "$image" \
  sh -c 'rm -rf /build/* /build/.[!.]* /build/..?*'

mkdir -p "$build_dir"
cp -a "$source_dir/." "$build_dir/src"
git -C "$build_dir/src" apply "$patch_file"
: > "$log_file"

if ! docker run --rm \
  -v "$build_dir:/build:z" \
  -w /build/src \
  "$image" \
  sh -euxc '
    CC="/opt/wasi-sdk/bin/clang --target=wasm32-wasip1-threads -pthread" \
    AR=/opt/wasi-sdk/bin/llvm-ar \
    RANLIB=/opt/wasi-sdk/bin/llvm-ranlib \
    CFLAGS="-DNO_SYSLOG" \
    ./Configure linux-generic32 \
      no-shared \
      no-dso \
      no-engine \
      no-tests \
      no-asm \
      no-async \
      no-threads \
      no-sock \
      no-secure-memory \
      no-ui-console \
      --prefix=/build/install \
      --openssldir=/build/install/ssl

    make -j2 build_generated libcrypto.a libssl.a
  ' > "$log_file" 2>&1; then
  tail -n 120 "$log_file"
  exit 1
fi

mkdir -p "$install_dir/include" "$install_dir/lib"
cp -a "$build_dir/src/include/openssl" "$install_dir/include/"
cp "$build_dir/src/libcrypto.a" "$build_dir/src/libssl.a" "$install_dir/lib/"

if ! printf '%s\n' \
  '#include <openssl/ssl.h>' \
  'int main(void) { SSL_CTX *ctx = SSL_CTX_new(TLS_method()); SSL_CTX_free(ctx); return 0; }' |
  docker run --rm -i \
    -v "$install_dir:/opt/openssl-wasi:ro,z" \
    "$image" \
    /opt/wasi-sdk/bin/clang \
      --target=wasm32-wasip1-threads \
      -pthread \
      -I/opt/openssl-wasi/include \
      -L/opt/openssl-wasi/lib \
      -x c - \
      -o /tmp/openssl-smoke.wasm \
      -lssl \
      -lcrypto \
      -lwasi-emulated-getpid >> "$log_file" 2>&1; then
  tail -n 120 "$log_file"
  exit 1
fi

printf 'OpenSSL WASI prefix: %s\n' "$install_dir"
printf 'MariaDB/OpenSSL extra link library: -lwasi-emulated-getpid\n'
