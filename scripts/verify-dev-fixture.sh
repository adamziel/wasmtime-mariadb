#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

cargo test --features dev-fixture
cargo run --bin wasmtime-mariadb --features dev-fixture -- --show-embedded-source
cargo run --bin wasmtime-mariadb --features dev-fixture
