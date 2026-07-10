-- Minimal MariaDB 11.4 system-table bootstrap for the WASI runner.
--
-- The runner deliberately starts with --skip-grant-tables, but MariaDB still
-- needs these metadata tables for routines and for its startup probes. Keep
-- this constrained to non-authentication tables required by local development.

CREATE DATABASE IF NOT EXISTS mysql;
USE mysql;

CREATE TABLE IF NOT EXISTS servers (
  Server_name char(64) NOT NULL DEFAULT '',
  Host varchar(2048) NOT NULL DEFAULT '',
  Db char(64) NOT NULL DEFAULT '',
  Username char(128) NOT NULL DEFAULT '',
  Password char(64) NOT NULL DEFAULT '',
  Port int(4) NOT NULL DEFAULT '0',
  Socket char(108) NOT NULL DEFAULT '',
  Wrapper char(64) NOT NULL DEFAULT '',
  Owner varchar(512) NOT NULL DEFAULT '',
  PRIMARY KEY (Server_name)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3
  COMMENT='MySQL Foreign Servers table';

CREATE TABLE IF NOT EXISTS proc (
  db char(64) COLLATE utf8mb3_bin DEFAULT '' NOT NULL,
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
  definer varchar(384) COLLATE utf8mb3_bin DEFAULT '' NOT NULL,
  created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  modified timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  sql_mode set('REAL_AS_FLOAT','PIPES_AS_CONCAT','ANSI_QUOTES','IGNORE_SPACE','IGNORE_BAD_TABLE_OPTIONS','ONLY_FULL_GROUP_BY','NO_UNSIGNED_SUBTRACTION','NO_DIR_IN_CREATE','POSTGRESQL','ORACLE','MSSQL','DB2','MAXDB','NO_KEY_OPTIONS','NO_TABLE_OPTIONS','NO_FIELD_OPTIONS','MYSQL323','MYSQL40','ANSI','NO_AUTO_VALUE_ON_ZERO','NO_BACKSLASH_ESCAPES','STRICT_TRANS_TABLES','STRICT_ALL_TABLES','NO_ZERO_IN_DATE','NO_ZERO_DATE','INVALID_DATES','ERROR_FOR_DIVISION_BY_ZERO','TRADITIONAL','NO_AUTO_CREATE_USER','HIGH_NOT_PRECEDENCE','NO_ENGINE_SUBSTITUTION','PAD_CHAR_TO_FULL_LENGTH','EMPTY_STRING_IS_NULL','SIMULTANEOUS_ASSIGNMENT','TIME_ROUND_FRACTIONAL') DEFAULT '' NOT NULL,
  comment text COLLATE utf8mb3_bin NOT NULL,
  character_set_client char(32) COLLATE utf8mb3_bin,
  collation_connection char(64) COLLATE utf8mb3_bin,
  db_collation char(64) COLLATE utf8mb3_bin,
  body_utf8 longblob,
  aggregate enum('NONE','GROUP') DEFAULT 'NONE' NOT NULL,
  PRIMARY KEY (db,name,type)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3
  COMMENT='Stored Procedures';

CREATE TABLE IF NOT EXISTS func (
  name char(64) binary DEFAULT '' NOT NULL,
  ret tinyint(1) DEFAULT '0' NOT NULL,
  dl char(128) DEFAULT '' NOT NULL,
  type enum('function','aggregate') COLLATE utf8mb3_general_ci NOT NULL,
  PRIMARY KEY (name)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin
  COMMENT='User defined functions';

-- These tables are empty by design. They allow HELP statements to run in the
-- stripped local-development bootstrap without bundling MariaDB's full help
-- corpus, and are needed by upstream implicit-commit coverage.
CREATE TABLE IF NOT EXISTS help_topic (
  help_topic_id int unsigned NOT NULL,
  name char(64) NOT NULL,
  help_category_id smallint unsigned NOT NULL,
  description text NOT NULL,
  example text NOT NULL,
  url text NOT NULL,
  PRIMARY KEY (help_topic_id),
  UNIQUE KEY name (name)
) ENGINE=Aria TRANSACTIONAL=0 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci
  COMMENT='help topics';

CREATE TABLE IF NOT EXISTS help_category (
  help_category_id smallint unsigned NOT NULL,
  name char(64) NOT NULL,
  parent_category_id smallint unsigned DEFAULT NULL,
  url text NOT NULL,
  PRIMARY KEY (help_category_id),
  UNIQUE KEY name (name)
) ENGINE=Aria TRANSACTIONAL=0 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci
  COMMENT='help categories';

CREATE TABLE IF NOT EXISTS help_keyword (
  help_keyword_id int unsigned NOT NULL,
  name char(64) NOT NULL,
  PRIMARY KEY (help_keyword_id),
  UNIQUE KEY name (name)
) ENGINE=Aria TRANSACTIONAL=0 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci
  COMMENT='help keywords';

CREATE TABLE IF NOT EXISTS help_relation (
  help_topic_id int unsigned NOT NULL,
  help_keyword_id int unsigned NOT NULL,
  PRIMARY KEY (help_keyword_id, help_topic_id)
) ENGINE=Aria TRANSACTIONAL=0 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci
  COMMENT='keyword-topic relation';

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
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin
  COMMENT='Procedure privileges';

CREATE TABLE IF NOT EXISTS time_zone_leap_second (
  Transition_time bigint signed NOT NULL,
  Correction int signed NOT NULL,
  PRIMARY KEY (Transition_time)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3
  COMMENT='Leap seconds information for time zones';
