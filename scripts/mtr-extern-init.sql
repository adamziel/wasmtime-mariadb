-- Minimal schema bootstrap for scripts/run-mtr-extern-smoke.sh.
--
-- The upstream MTR warning bootstrap expects a fully initialized mysql system
-- schema. This file creates only the pieces needed for external smoke tests to
-- reach the server behavior under test.

CREATE DATABASE IF NOT EXISTS mysql;
CREATE DATABASE IF NOT EXISTS test;
CREATE DATABASE IF NOT EXISTS mtr;

USE mysql;

CREATE TABLE IF NOT EXISTS global_priv (
  Host char(255) binary DEFAULT '',
  User char(128) binary DEFAULT '',
  Priv JSON NOT NULL DEFAULT '{}' CHECK(JSON_VALID(Priv)),
  PRIMARY KEY (Host,User)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Users and global privileges';

INSERT IGNORE INTO global_priv (Host, User, Priv) VALUES
  ('localhost', 'root', '{"access":18446744073709551615,"plugin":"mysql_native_password","authentication_string":"","auth_or":[{},{"plugin":"unix_socket"}]}'),
  ('127.0.0.1', 'root', '{"access":18446744073709551615,"plugin":"mysql_native_password","authentication_string":""}'),
  ('::1', 'root', '{"access":18446744073709551615,"plugin":"mysql_native_password","authentication_string":""}'),
  ('', 'PUBLIC', '{"access":0,"is_role":true}');

CREATE TABLE IF NOT EXISTS db (
  Host char(255) binary DEFAULT '' NOT NULL,
  Db char(64) binary DEFAULT '' NOT NULL,
  User char(128) binary DEFAULT '' NOT NULL,
  Select_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Insert_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Update_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Delete_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Create_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Drop_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Grant_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  References_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Index_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Alter_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Create_tmp_table_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Lock_tables_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Create_view_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Show_view_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Create_routine_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Alter_routine_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Execute_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Event_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Trigger_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Delete_history_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  Show_create_routine_priv enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  PRIMARY KEY (Host,Db,User),
  KEY User (User)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Database privileges';

CREATE TABLE IF NOT EXISTS tables_priv (
  Host char(255) binary DEFAULT '' NOT NULL,
  Db char(64) binary DEFAULT '' NOT NULL,
  User char(128) binary DEFAULT '' NOT NULL,
  Table_name char(64) binary DEFAULT '' NOT NULL,
  Grantor varchar(384) DEFAULT '' NOT NULL,
  Timestamp timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  Table_priv set('Select','Insert','Update','Delete','Create','Drop','Grant','References','Index','Alter','Create View','Show view','Trigger','Delete versioning rows') COLLATE utf8mb3_general_ci DEFAULT '' NOT NULL,
  Column_priv set('Select','Insert','Update','References') COLLATE utf8mb3_general_ci DEFAULT '' NOT NULL,
  PRIMARY KEY (Host,Db,User,Table_name),
  KEY Grantor (Grantor)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Table privileges';

CREATE TABLE IF NOT EXISTS columns_priv (
  Host char(255) binary DEFAULT '' NOT NULL,
  Db char(64) binary DEFAULT '' NOT NULL,
  User char(128) binary DEFAULT '' NOT NULL,
  Table_name char(64) binary DEFAULT '' NOT NULL,
  Column_name char(64) binary DEFAULT '' NOT NULL,
  Timestamp timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  Column_priv set('Select','Insert','Update','References') COLLATE utf8mb3_general_ci DEFAULT '' NOT NULL,
  PRIMARY KEY (Host,Db,User,Table_name,Column_name)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Column privileges';

CREATE TABLE IF NOT EXISTS roles_mapping (
  Host char(255) binary DEFAULT '' NOT NULL,
  User char(128) binary DEFAULT '' NOT NULL,
  Role char(128) binary DEFAULT '' NOT NULL,
  Admin_option enum('N','Y') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  UNIQUE (Host,User,Role)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Granted roles';

CREATE TABLE IF NOT EXISTS plugin (
  name varchar(64) DEFAULT '' NOT NULL,
  dl varchar(128) DEFAULT '' NOT NULL,
  PRIMARY KEY (name)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci COMMENT='MySQL plugins';

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='MySQL Foreign Servers table';

CREATE TABLE IF NOT EXISTS proxies_priv (
  Host char(255) binary DEFAULT '' NOT NULL,
  User char(128) binary DEFAULT '' NOT NULL,
  Proxied_host char(255) binary DEFAULT '' NOT NULL,
  Proxied_user char(128) binary DEFAULT '' NOT NULL,
  With_grant bool DEFAULT 0 NOT NULL,
  Grantor varchar(384) DEFAULT '' NOT NULL,
  Timestamp timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (Host,User,Proxied_host,Proxied_user),
  KEY Grantor (Grantor)
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='User proxy privileges';

INSERT IGNORE INTO proxies_priv (Host, User, Proxied_host, Proxied_user, With_grant, Grantor)
VALUES ('localhost', 'root', '', '', TRUE, '');

CREATE TABLE IF NOT EXISTS event (
  db char(64) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL DEFAULT '',
  name char(64) CHARACTER SET utf8mb3 NOT NULL DEFAULT '',
  body longblob NOT NULL,
  definer varchar(384) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL DEFAULT '',
  execute_at datetime DEFAULT NULL,
  interval_value int(11) DEFAULT NULL,
  interval_field enum('YEAR','QUARTER','MONTH','DAY','HOUR','MINUTE','WEEK','SECOND','MICROSECOND','YEAR_MONTH','DAY_HOUR','DAY_MINUTE','DAY_SECOND','HOUR_MINUTE','HOUR_SECOND','MINUTE_SECOND','DAY_MICROSECOND','HOUR_MICROSECOND','MINUTE_MICROSECOND','SECOND_MICROSECOND') DEFAULT NULL,
  created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  modified timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  last_executed datetime DEFAULT NULL,
  starts datetime DEFAULT NULL,
  ends datetime DEFAULT NULL,
  status enum('ENABLED','DISABLED','SLAVESIDE_DISABLED') NOT NULL DEFAULT 'ENABLED',
  on_completion enum('DROP','PRESERVE') NOT NULL DEFAULT 'DROP',
  sql_mode set('REAL_AS_FLOAT','PIPES_AS_CONCAT','ANSI_QUOTES','IGNORE_SPACE','IGNORE_BAD_TABLE_OPTIONS','ONLY_FULL_GROUP_BY','NO_UNSIGNED_SUBTRACTION','NO_DIR_IN_CREATE','POSTGRESQL','ORACLE','MSSQL','DB2','MAXDB','NO_KEY_OPTIONS','NO_TABLE_OPTIONS','NO_FIELD_OPTIONS','MYSQL323','MYSQL40','ANSI','NO_AUTO_VALUE_ON_ZERO','NO_BACKSLASH_ESCAPES','STRICT_TRANS_TABLES','STRICT_ALL_TABLES','NO_ZERO_IN_DATE','NO_ZERO_DATE','INVALID_DATES','ERROR_FOR_DIVISION_BY_ZERO','TRADITIONAL','NO_AUTO_CREATE_USER','HIGH_NOT_PRECEDENCE','NO_ENGINE_SUBSTITUTION','PAD_CHAR_TO_FULL_LENGTH','EMPTY_STRING_IS_NULL','SIMULTANEOUS_ASSIGNMENT','TIME_ROUND_FRACTIONAL') DEFAULT '' NOT NULL,
  comment char(64) CHARACTER SET utf8mb3 COLLATE utf8mb3_bin NOT NULL DEFAULT '',
  originator int unsigned NOT NULL,
  time_zone char(64) CHARACTER SET latin1 NOT NULL DEFAULT 'SYSTEM',
  character_set_client char(32) COLLATE utf8mb3_bin,
  collation_connection char(64) COLLATE utf8mb3_bin,
  db_collation char(64) COLLATE utf8mb3_bin,
  body_utf8 longblob,
  PRIMARY KEY (db,name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Events';

SET @have_csv = (
  SELECT COUNT(*) FROM information_schema.engines
  WHERE engine = 'CSV' AND support <> 'NO'
);
SET @create_general_log = IF(
  @have_csv <> 0,
  'CREATE TABLE IF NOT EXISTS general_log (event_time TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, user_host MEDIUMTEXT NOT NULL, thread_id BIGINT(21) UNSIGNED NOT NULL, server_id INTEGER UNSIGNED NOT NULL, command_type VARCHAR(64) NOT NULL, argument MEDIUMTEXT NOT NULL) ENGINE=CSV DEFAULT CHARSET=utf8mb3 COMMENT="General log"',
  'CREATE TABLE IF NOT EXISTS general_log (event_time TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, user_host MEDIUMTEXT NOT NULL, thread_id BIGINT(21) UNSIGNED NOT NULL, server_id INTEGER UNSIGNED NOT NULL, command_type VARCHAR(64) NOT NULL, argument MEDIUMTEXT NOT NULL) ENGINE=Aria TRANSACTIONAL=0 DEFAULT CHARSET=utf8mb3 COMMENT="General log"'
);
PREPARE stmt FROM @create_general_log;
EXECUTE stmt;
DROP PREPARE stmt;

SET @create_slow_log = IF(
  @have_csv <> 0,
  'CREATE TABLE IF NOT EXISTS slow_log (start_time TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, user_host MEDIUMTEXT NOT NULL, query_time TIME(6) NOT NULL, lock_time TIME(6) NOT NULL, rows_sent BIGINT UNSIGNED NOT NULL, rows_examined BIGINT UNSIGNED NOT NULL, db VARCHAR(512) NOT NULL, last_insert_id INTEGER NOT NULL, insert_id INTEGER NOT NULL, server_id INTEGER UNSIGNED NOT NULL, sql_text MEDIUMTEXT NOT NULL, thread_id BIGINT(21) UNSIGNED NOT NULL, rows_affected BIGINT UNSIGNED NOT NULL) ENGINE=CSV DEFAULT CHARSET=utf8mb3 COMMENT="Slow log"',
  'CREATE TABLE IF NOT EXISTS slow_log (start_time TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, user_host MEDIUMTEXT NOT NULL, query_time TIME(6) NOT NULL, lock_time TIME(6) NOT NULL, rows_sent BIGINT UNSIGNED NOT NULL, rows_examined BIGINT UNSIGNED NOT NULL, db VARCHAR(512) NOT NULL, last_insert_id INTEGER NOT NULL, insert_id INTEGER NOT NULL, server_id INTEGER UNSIGNED NOT NULL, sql_text MEDIUMTEXT NOT NULL, thread_id BIGINT(21) UNSIGNED NOT NULL, rows_affected BIGINT UNSIGNED NOT NULL) ENGINE=Aria TRANSACTIONAL=0 DEFAULT CHARSET=utf8mb3 COMMENT="Slow log"'
);
PREPARE stmt FROM @create_slow_log;
EXECUTE stmt;
DROP PREPARE stmt;

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
) ENGINE=Aria TRANSACTIONAL=1 DEFAULT CHARSET=utf8mb3 COMMENT='Stored Procedures';

CREATE TABLE IF NOT EXISTS func (
  name char(64) binary DEFAULT '' NOT NULL,
  ret tinyint(1) DEFAULT '0' NOT NULL,
  dl char(128) DEFAULT '' NOT NULL,
  type enum('function','aggregate') COLLATE utf8mb3_general_ci NOT NULL,
  PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='User defined functions';

CREATE TABLE IF NOT EXISTS time_zone_name (
  Name char(64) NOT NULL,
  Time_zone_id int unsigned NOT NULL,
  PRIMARY KEY (Name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Time zone names';

CREATE TABLE IF NOT EXISTS time_zone (
  Time_zone_id int unsigned NOT NULL auto_increment,
  Use_leap_seconds enum('Y','N') COLLATE utf8mb3_general_ci DEFAULT 'N' NOT NULL,
  PRIMARY KEY (Time_zone_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Time zones';

CREATE TABLE IF NOT EXISTS time_zone_transition (
  Time_zone_id int unsigned NOT NULL,
  Transition_time bigint signed NOT NULL,
  Transition_type_id int unsigned NOT NULL,
  PRIMARY KEY (Time_zone_id, Transition_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Time zone transitions';

CREATE TABLE IF NOT EXISTS time_zone_transition_type (
  Time_zone_id int unsigned NOT NULL,
  Transition_type_id int unsigned NOT NULL,
  `Offset` int signed DEFAULT 0 NOT NULL,
  Is_DST tinyint unsigned DEFAULT 0 NOT NULL,
  Abbreviation char(8) DEFAULT '' NOT NULL,
  PRIMARY KEY (Time_zone_id, Transition_type_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Time zone transition types';

CREATE TABLE IF NOT EXISTS time_zone_leap_second (
  Transition_time bigint signed NOT NULL,
  Correction int signed NOT NULL,
  PRIMARY KEY (Transition_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COMMENT='Leap seconds information for time zones';

CREATE TABLE IF NOT EXISTS table_stats (
  db_name varchar(64) NOT NULL,
  table_name varchar(64) NOT NULL,
  cardinality bigint(21) unsigned DEFAULT NULL,
  PRIMARY KEY (db_name,table_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Statistics on Tables';

CREATE TABLE IF NOT EXISTS column_stats (
  db_name varchar(64) NOT NULL,
  table_name varchar(64) NOT NULL,
  column_name varchar(64) NOT NULL,
  min_value varbinary(255) DEFAULT NULL,
  max_value varbinary(255) DEFAULT NULL,
  nulls_ratio decimal(12,4) DEFAULT NULL,
  avg_length decimal(12,4) DEFAULT NULL,
  avg_frequency decimal(12,4) DEFAULT NULL,
  hist_size tinyint unsigned,
  hist_type enum('SINGLE_PREC_HB','DOUBLE_PREC_HB','JSON_HB'),
  histogram longblob,
  PRIMARY KEY (db_name,table_name,column_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Statistics on Columns';

CREATE TABLE IF NOT EXISTS index_stats (
  db_name varchar(64) NOT NULL,
  table_name varchar(64) NOT NULL,
  index_name varchar(64) NOT NULL,
  prefix_arity int(11) unsigned NOT NULL,
  avg_frequency decimal(12,4) DEFAULT NULL,
  PRIMARY KEY (db_name,table_name,index_name,prefix_arity)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_bin COMMENT='Statistics on Indexes';

CREATE TABLE IF NOT EXISTS gtid_slave_pos (
  domain_id int unsigned NOT NULL,
  sub_id bigint unsigned NOT NULL,
  server_id int unsigned NOT NULL,
  seq_no bigint unsigned NOT NULL,
  PRIMARY KEY (domain_id, sub_id)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COMMENT='Replication slave GTID position';

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
