#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
php="${PHP:-php}"
wp_tests_dir="${WP_TESTS_DIR:?set WP_TESTS_DIR to a WordPress test library}"
woocommerce_dir="${WOOCOMMERCE_DIR:?set WOOCOMMERCE_DIR to a WooCommerce checkout}"
wp_tests_config="${WP_TESTS_CONFIG_FILE_PATH:-$wp_tests_dir/wp-tests-config.php}"
phpunit="$woocommerce_dir/vendor/bin/phpunit"

if [[ ! -f "$wp_tests_dir/includes/install.php" ]]; then
  echo "WordPress test installer not found: $wp_tests_dir/includes/install.php" >&2
  exit 2
fi
if [[ ! -f "$wp_tests_config" ]]; then
  echo "WordPress test config not found: $wp_tests_config" >&2
  exit 2
fi
if [[ ! -x "$phpunit" ]]; then
  echo "WooCommerce PHPUnit binary not found: $phpunit" >&2
  exit 2
fi
if [[ ! -f "$woocommerce_dir/woocommerce.php" ]]; then
  echo "WooCommerce plugin entrypoint not found: $woocommerce_dir/woocommerce.php" >&2
  exit 2
fi

# Run the WordPress installer outside PHPUnit so its CLI output cannot break
# tests that exercise HTTP headers or cookies.
"$php" "$wp_tests_dir/includes/install.php" "$wp_tests_config" no_ms_tests no_core_tests

cd "$root"
WP_TESTS_DIR="$wp_tests_dir" \
WP_TESTS_CONFIG_FILE_PATH="$wp_tests_config" \
WP_TESTS_SKIP_INSTALL=1 \
WOOCOMMERCE_DIR="$woocommerce_dir" \
"$php" -d output_buffering=4096 "$phpunit" \
  --do-not-cache-result \
  --bootstrap "$root/tests/wordpress-woocommerce-bootstrap.php" \
  "$root/tests/WasmtimeMariaDBWordPressWooCommerceTest.php"
