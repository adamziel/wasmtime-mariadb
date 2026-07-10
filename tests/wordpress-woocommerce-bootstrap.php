<?php

$wp_tests_dir = getenv( 'WP_TESTS_DIR' );
$woocommerce_dir = getenv( 'WOOCOMMERCE_DIR' );
$wp_tests_config = getenv( 'WP_TESTS_CONFIG_FILE_PATH' );

if ( ! $wp_tests_dir || ! is_dir( $wp_tests_dir ) ) {
	fwrite( STDERR, "WP_TESTS_DIR must point to a WordPress test library.\n" );
	exit( 2 );
}

if ( ! $woocommerce_dir || ! is_file( $woocommerce_dir . '/woocommerce.php' ) ) {
	fwrite( STDERR, "WOOCOMMERCE_DIR must point to a WooCommerce checkout.\n" );
	exit( 2 );
}

if ( $wp_tests_config ) {
	define( 'WP_TESTS_CONFIG_FILE_PATH', $wp_tests_config );
}

if ( ! defined( 'WP_TESTS_PHPUNIT_POLYFILLS_PATH' ) ) {
	define( 'WP_TESTS_PHPUNIT_POLYFILLS_PATH', $woocommerce_dir . '/vendor/yoast/phpunit-polyfills' );
}

require_once $wp_tests_dir . '/includes/functions.php';

tests_add_filter(
	'muplugins_loaded',
	static function () use ( $woocommerce_dir ) {
		require_once $woocommerce_dir . '/woocommerce.php';
	}
);

tests_add_filter(
	'setup_theme',
	static function () {
		WC_Install::install();
	}
);

require_once $wp_tests_dir . '/includes/bootstrap.php';
