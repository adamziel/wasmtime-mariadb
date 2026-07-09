#!/usr/bin/env bash
set -euo pipefail

port="${PORT:-3307}"
host="${HOST:-127.0.0.1}"
client="${MYSQL:-mysql}"

if ! command -v "$client" >/dev/null 2>&1; then
  echo "mysql client not found: $client" >&2
  echo "On macOS, install one with: brew install mysql-client" >&2
  echo "Then retry with MYSQL=/opt/homebrew/opt/mysql-client/bin/mysql if needed." >&2
  exit 2
fi

ssl_arg=(--ssl-mode=DISABLED)
case "$(basename "$client")" in
  mariadb|mariadb-*)
    ssl_arg=(--ssl=0)
    ;;
esac

table="mysql_client_smoke_$(date +%s)_$$"

"$client" \
  --protocol=TCP \
  -h"$host" \
  -P"$port" \
  -uroot \
  "${ssl_arg[@]}" <<SQL
SELECT VERSION();
CREATE DATABASE IF NOT EXISTS smoke;
CREATE TABLE smoke.$table (id INT PRIMARY KEY, payload VARCHAR(64));
INSERT INTO smoke.$table VALUES (1, 'hello from mysql client');
SELECT * FROM smoke.$table;
SELECT ENGINE FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = 'smoke' AND TABLE_NAME = '$table';
SQL
