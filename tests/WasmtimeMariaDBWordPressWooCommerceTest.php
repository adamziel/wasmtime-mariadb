<?php

class WasmtimeMariaDBWordPressWooCommerceTest extends WP_UnitTestCase {
	public function test_can_save_a_page() {
		$page_id = wp_insert_post(
			array(
				'post_title'   => 'Wasmtime MariaDB page',
				'post_content' => 'Saved through the WordPress API.',
				'post_status'  => 'publish',
				'post_type'    => 'page',
			),
			true
		);

		$this->assertNotWPError( $page_id );
		$this->assertGreaterThan( 0, $page_id );

		$updated_id = wp_update_post(
			array(
				'ID'           => $page_id,
				'post_content' => 'Updated through the WordPress API.',
			),
			true
		);

		$this->assertSame( $page_id, $updated_id );
		$this->assertSame( 'Updated through the WordPress API.', get_post_field( 'post_content', $page_id ) );
	}

	public function test_can_save_a_product_and_order() {
		$product = new WC_Product_Simple();
		$product->set_name( 'Wasmtime MariaDB product' );
		$product->set_regular_price( '19.99' );
		$product->set_manage_stock( true );
		$product->set_stock_quantity( 6 );
		$product->set_status( 'publish' );
		$product_id = $product->save();

		$this->assertGreaterThan( 0, $product_id );

		$stored_product = wc_get_product( $product_id );
		$this->assertInstanceOf( WC_Product_Simple::class, $stored_product );
		$this->assertSame( 'Wasmtime MariaDB product', $stored_product->get_name() );
		$this->assertSame( '19.99', $stored_product->get_regular_price() );
		$this->assertSame( 6, $stored_product->get_stock_quantity() );

		$order = wc_create_order();
		$order->add_product( $stored_product, 2 );
		$order->calculate_totals();
		$order->set_status( 'processing' );
		$order_id = $order->save();

		$this->assertGreaterThan( 0, $order_id );

		$stored_order = wc_get_order( $order_id );
		$this->assertInstanceOf( WC_Order::class, $stored_order );
		$this->assertSame( '39.98', $stored_order->get_total() );

		$items = $stored_order->get_items();
		$this->assertCount( 1, $items );
		$item = current( $items );
		$this->assertSame( 2, $item->get_quantity() );
		$this->assertSame( $product_id, $item->get_product_id() );
	}

	public function test_innodb_transactions_commit_and_rollback() {
		global $wpdb;

		$table = $wpdb->prefix . 'wasmtime_transaction_smoke';

		$this->assertNotFalse(
			$wpdb->query(
				"CREATE TABLE `$table` (id int unsigned NOT NULL, payload varchar(64) NOT NULL, PRIMARY KEY (id)) ENGINE=InnoDB"
			)
		);

		try {
			$this->assertNotFalse( $wpdb->query( 'START TRANSACTION' ) );
			$this->assertSame( 1, $wpdb->insert( $table, array( 'id' => 1, 'payload' => 'rolled back' ), array( '%d', '%s' ) ) );
			$this->assertNotFalse( $wpdb->query( 'ROLLBACK' ) );
			$this->assertSame( '0', $wpdb->get_var( "SELECT COUNT(*) FROM `$table`" ) );

			$this->assertNotFalse( $wpdb->query( 'START TRANSACTION' ) );
			$this->assertSame( 1, $wpdb->insert( $table, array( 'id' => 2, 'payload' => 'committed' ), array( '%d', '%s' ) ) );
			$this->assertNotFalse( $wpdb->query( 'COMMIT' ) );
			$this->assertSame( 'committed', $wpdb->get_var( "SELECT payload FROM `$table` WHERE id = 2" ) );
		} finally {
			$wpdb->query( "DROP TABLE IF EXISTS `$table`" );
		}
	}
}
