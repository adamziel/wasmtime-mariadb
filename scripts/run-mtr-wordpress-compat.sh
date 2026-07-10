#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OUT_DIR="${OUT_DIR:-$root/build/mtr-wordpress-compat}"
export MTR_PRESERVE_VARDIRS="${MTR_PRESERVE_VARDIRS:-0}"

# This profile concentrates on WordPress core's normal SQL and InnoDB path.
tests=(
  main.select main.insert main.update main.delete main.create main.drop
  main.type_int main.type_varchar main.func_math main.func_str main.join
  main.union main.order_by main.group_by main.subselect main.ps main.prepare
  main.information_schema innodb.innodb innodb.create_select
  innodb.foreign_key innodb.alter_table
  main.auto_increment main.create_select main.insert_select main.insert_update
  main.replace main.commit main.commit_1innodb main.rollback main.delete_innodb
  main.insert_innodb main.update_innodb main.func_concat main.func_date_add
  main.func_gconcat main.func_if main.func_in main.func_like main.func_misc
  main.func_op main.func_replace main.func_time main.func_timestamp
  main.group_by_innodb main.join_outer_innodb main.order_by_innodb
  main.union_innodb main.subselect_innodb main.select_found
  main.information_schema_columns main.information_schema_tables
  main.information_schema_stats main.information_schema_temp_table
  main.sql_mode main.ps_3innodb main.type_binary main.type_bit_innodb
  main.type_date main.type_datetime main.type_decimal main.type_enum
  main.type_json main.type_set main.type_temporal_innodb main.type_timestamp
  main.type_varbinary main.locking_clause
  innodb.innodb-on-duplicate-update
  innodb.innodb-update-insert innodb.innodb-index innodb.innodb-lock
  innodb.innodb-rollback innodb.temp_table
  innodb.create-index innodb.add_foreign_key innodb.alter_varchar_change
  innodb.instant_alter innodb.innodb-alter innodb.innodb-alter-table
  main.create_utf8 main.create-uca main.ctype_utf8 main.ctype_utf8mb4
  main.ctype_utf8mb4_innodb main.ctype_utf8mb4_unicode_520_ci_casefold
  main.ctype_collate main.ctype_collate_database main.ctype_uca_innodb
  main.alter_table main.alter_table_trans main.create_drop_index main.lock
  main.show main.show_explain main.show_explain_json main.func_json
  innodb.create_like innodb.index_length innodb.innodb_multi_update
  innodb.lock_isolation innodb.lock_release innodb.row_lock
  innodb.skip_locked_nowait innodb.update-cascade
)

exec "$root/scripts/run-mtr-extern-smoke.sh" "${tests[@]}"
