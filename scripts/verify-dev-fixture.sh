#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

cargo test --features dev-fixture
cargo run --features dev-fixture -- --show-embedded-source
cargo run --features dev-fixture
