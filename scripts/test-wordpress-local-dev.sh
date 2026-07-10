#!/usr/bin/env bash
set -euo pipefail

host="${HOST:-127.0.0.1}"
port="${PORT:-3307}"
client="${MYSQL:-mysql}"
database="wp_wasmtime_smoke_$(date +%s)_$$"

if ! command -v "$client" >/dev/null 2>&1; then
  echo "mysql client not found: $client" >&2
  echo "On macOS, install one with: brew install mysql-client" >&2
  exit 2
fi

ssl_args=(--ssl-mode=DISABLED)
client_version="$("$client" --version 2>&1 || true)"
case "$client_version" in
  *MariaDB*|*mariadb*) ssl_args=(--ssl=0) ;;
esac

client_args=(--protocol=TCP "-h$host" "-P$port" -uroot "${ssl_args[@]}")

cleanup() {
  "$client" "${client_args[@]}" -e "DROP DATABASE IF EXISTS \`$database\`" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$client" "${client_args[@]}" -e \
  "CREATE DATABASE \`$database\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci"

"$client" "${client_args[@]}" --database="$database" --batch --raw <<'SQL'
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_520_ci;
SET lc_time_names = 'fr_FR';

CREATE TABLE wp_posts (
  ID bigint(20) unsigned NOT NULL auto_increment,
  post_author bigint(20) unsigned NOT NULL default 0,
  post_date datetime NOT NULL default '0000-00-00 00:00:00',
  post_date_gmt datetime NOT NULL default '0000-00-00 00:00:00',
  post_content longtext NOT NULL,
  post_title text NOT NULL,
  post_excerpt text NOT NULL,
  post_status varchar(20) NOT NULL default 'publish',
  post_name varchar(200) NOT NULL default '',
  post_modified datetime NOT NULL default '0000-00-00 00:00:00',
  post_type varchar(20) NOT NULL default 'post',
  post_parent bigint(20) unsigned NOT NULL default 0,
  PRIMARY KEY (ID),
  KEY post_name (post_name(191)),
  KEY type_status_date (post_type, post_status, post_date, ID),
  KEY post_parent (post_parent),
  KEY post_author (post_author)
) ENGINE=InnoDB;

CREATE TABLE wp_options (
  option_id bigint(20) unsigned NOT NULL auto_increment,
  option_name varchar(191) NOT NULL default '',
  option_value longtext NOT NULL,
  autoload varchar(20) NOT NULL default 'yes',
  PRIMARY KEY (option_id),
  UNIQUE KEY option_name (option_name),
  KEY autoload (autoload)
) ENGINE=InnoDB;

CREATE TABLE wp_postmeta (
  meta_id bigint(20) unsigned NOT NULL auto_increment,
  post_id bigint(20) unsigned NOT NULL default 0,
  meta_key varchar(255) default NULL,
  meta_value longtext,
  PRIMARY KEY (meta_id),
  KEY post_id (post_id),
  KEY meta_key (meta_key(191))
) ENGINE=InnoDB;

CREATE TABLE wp_terms (
  term_id bigint(20) unsigned NOT NULL auto_increment,
  name varchar(200) NOT NULL default '',
  slug varchar(200) NOT NULL default '',
  term_group bigint(10) NOT NULL default 0,
  PRIMARY KEY (term_id),
  KEY slug (slug(191)),
  KEY name (name(191))
) ENGINE=InnoDB;

CREATE TABLE wp_term_taxonomy (
  term_taxonomy_id bigint(20) unsigned NOT NULL auto_increment,
  term_id bigint(20) unsigned NOT NULL default 0,
  taxonomy varchar(32) NOT NULL default '',
  description longtext NOT NULL,
  parent bigint(20) unsigned NOT NULL default 0,
  count bigint(20) NOT NULL default 0,
  PRIMARY KEY (term_taxonomy_id),
  UNIQUE KEY term_id_taxonomy (term_id, taxonomy),
  KEY taxonomy (taxonomy)
) ENGINE=InnoDB;

CREATE TABLE wp_term_relationships (
  object_id bigint(20) unsigned NOT NULL default 0,
  term_taxonomy_id bigint(20) unsigned NOT NULL default 0,
  term_order int(11) NOT NULL default 0,
  PRIMARY KEY (object_id, term_taxonomy_id),
  KEY term_taxonomy_id (term_taxonomy_id)
) ENGINE=InnoDB;

INSERT INTO wp_posts
  (post_author, post_date, post_date_gmt, post_content, post_title, post_excerpt, post_name)
VALUES
  (1, '2026-07-09 12:00:00', '2026-07-09 12:00:00',
   CONCAT('hello ', CONVERT(0xF09F9A80 USING utf8mb4), REPEAT('x', 1048576)),
   'Wasmtime MariaDB', '', 'wasmtime-mariadb');

INSERT INTO wp_options (option_name, option_value, autoload)
VALUES ('siteurl', 'http://example.test', 'yes')
ON DUPLICATE KEY UPDATE option_value = VALUES(option_value);

INSERT INTO wp_postmeta (post_id, meta_key, meta_value)
VALUES (1, '_edit_lock', '1:1');
INSERT INTO wp_terms (name, slug) VALUES ('News', 'news');
INSERT INTO wp_term_taxonomy (term_id, taxonomy, description, count)
VALUES (1, 'category', '', 1);
INSERT INTO wp_term_relationships (object_id, term_taxonomy_id) VALUES (1, 1);

START TRANSACTION;
UPDATE wp_options SET option_value = 'http://localhost' WHERE option_name = 'siteurl';
COMMIT;

SELECT @@lc_time_names AS locale, DATE_FORMAT('2026-07-09', '%W %M') AS localized_date;
SELECT SQL_CALC_FOUND_ROWS p.ID, OCTET_LENGTH(p.post_content) AS post_content_bytes
FROM wp_posts AS p
INNER JOIN wp_term_relationships AS tr ON tr.object_id = p.ID
INNER JOIN wp_term_taxonomy AS tt ON tt.term_taxonomy_id = tr.term_taxonomy_id
WHERE p.post_type = 'post' AND p.post_status = 'publish' AND tt.taxonomy = 'category'
ORDER BY p.post_date DESC LIMIT 1;
SELECT FOUND_ROWS() AS found_rows;
SELECT option_value FROM wp_options WHERE option_name = 'siteurl';
SHOW COLUMNS FROM wp_posts LIKE 'post_content';
SHOW INDEX FROM wp_posts WHERE Key_name = 'type_status_date';
SHOW TABLE STATUS LIKE 'wp_posts';
ALTER TABLE wp_posts ADD KEY wasmtime_smoke_author_date (post_author, post_date);
SELECT ENGINE, TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'wp_posts';

DELIMITER //
CREATE PROCEDURE wp_wasmtime_smoke_post_count()
BEGIN
  SELECT COUNT(*) AS post_count FROM wp_posts;
END//
DELIMITER ;
CALL wp_wasmtime_smoke_post_count();
DROP PROCEDURE wp_wasmtime_smoke_post_count;

CREATE FUNCTION wp_wasmtime_smoke_title_length()
RETURNS INT DETERMINISTIC
RETURN (SELECT CHAR_LENGTH(post_title) FROM wp_posts WHERE ID = 1);
SELECT wp_wasmtime_smoke_title_length() AS title_length;
DROP FUNCTION wp_wasmtime_smoke_title_length;
SQL

printf 'WordPress local-development SQL smoke passed on %s:%s.\n' "$host" "$port"
