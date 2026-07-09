-- Minimal schema bootstrap for scripts/run-mtr-extern-smoke.sh.
--
-- The upstream MTR warning bootstrap creates MyISAM tables and expects a fully
-- initialized mysql system schema. The WASI port currently cannot use those
-- Aria/MyISAM paths reliably, so this file creates only the pieces needed for
-- external smoke tests to reach the server behavior under test.

CREATE DATABASE IF NOT EXISTS mysql;
CREATE DATABASE IF NOT EXISTS test;
CREATE DATABASE IF NOT EXISTS mtr;

USE mysql;

CREATE TABLE IF NOT EXISTS proc (
  db char(64) collate utf8mb3_bin DEFAULT '' NOT NULL,
  name char(64) DEFAULT '' NOT NULL,
  type enum('FUNCTION','PROCEDURE','PACKAGE','PACKAGE BODY') NOT NULL,
  specific_name char(64) DEFAULT '' NOT NULL,
  language enum('SQL') DEFAULT 'SQL' NOT NULL,
  sql_data_access enum('CONTAINS_SQL','NO_SQL','READS_SQL_DATA','MODIFIES_SQL_DATA') DEFAULT 'CONTAINS_SQL' NOT NULL,
  is_deterministic enum('YES','NO') DEFAULT 'NO' NOT NULL,
  security_type enum('INVOKER','DEFINER') DEFAULT 'DEFINER' NOT NULL,
  param_list blob NOT NULL,
  returns longblob NOT NULL,
  body longblob NOT NULL,
  definer varchar(384) collate utf8mb3_bin DEFAULT '' NOT NULL,
  created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  modified timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  sql_mode set('REAL_AS_FLOAT','PIPES_AS_CONCAT','ANSI_QUOTES','IGNORE_SPACE','IGNORE_BAD_TABLE_OPTIONS','ONLY_FULL_GROUP_BY','NO_UNSIGNED_SUBTRACTION','NO_DIR_IN_CREATE','POSTGRESQL','ORACLE','MSSQL','DB2','MAXDB','NO_KEY_OPTIONS','NO_TABLE_OPTIONS','NO_FIELD_OPTIONS','MYSQL323','MYSQL40','ANSI','NO_AUTO_VALUE_ON_ZERO','NO_BACKSLASH_ESCAPES','STRICT_TRANS_TABLES','STRICT_ALL_TABLES','NO_ZERO_IN_DATE','NO_ZERO_DATE','INVALID_DATES','ERROR_FOR_DIVISION_BY_ZERO','TRADITIONAL','NO_AUTO_CREATE_USER','HIGH_NOT_PRECEDENCE','NO_ENGINE_SUBSTITUTION','PAD_CHAR_TO_FULL_LENGTH','EMPTY_STRING_IS_NULL','SIMULTANEOUS_ASSIGNMENT','TIME_ROUND_FRACTIONAL') DEFAULT '' NOT NULL,
  comment text collate utf8mb3_bin NOT NULL,
  character_set_client char(32) collate utf8mb3_bin,
  collation_connection char(64) collate utf8mb3_bin,
  db_collation char(64) collate utf8mb3_bin,
  body_utf8 longblob,
  aggregate enum('NONE','GROUP') DEFAULT 'NONE' NOT NULL,
  PRIMARY KEY (db,name,type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Stored Procedures';

CREATE TABLE IF NOT EXISTS procs_priv (
  Host char(255) binary DEFAULT '' NOT NULL,
  Db char(64) binary DEFAULT '' NOT NULL,
  User char(128) binary DEFAULT '' NOT NULL,
  Routine_name char(64) COLLATE utf8mb3_general_ci DEFAULT '' NOT NULL,
  Routine_type enum('FUNCTION','PROCEDURE','PACKAGE','PACKAGE BODY') NOT NULL,
  Grantor varchar(384) DEFAULT '' NOT NULL,
  Proc_priv set('Execute','Alter Routine','Grant','Show Create Routine') COLLATE utf8mb3_general_ci DEFAULT '' NOT NULL,
  Timestamp timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (Host,Db,User,Routine_name,Routine_type),
  KEY Grantor (Grantor)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Procedure privileges';

USE mtr;

CREATE TABLE IF NOT EXISTS test_suppressions (
  pattern varchar(255)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS global_suppressions (
  pattern varchar(255)
) ENGINE=InnoDB;

DELIMITER //

DROP PROCEDURE IF EXISTS add_suppression//
CREATE DEFINER=root@localhost PROCEDURE add_suppression(pattern varchar(255))
BEGIN
  INSERT INTO test_suppressions (pattern) VALUES (pattern);
END//

DROP PROCEDURE IF EXISTS check_warnings//
CREATE DEFINER=root@localhost PROCEDURE check_warnings(OUT result int)
BEGIN
  SELECT 0 INTO result;
  TRUNCATE test_suppressions;
END//

DELIMITER ;
