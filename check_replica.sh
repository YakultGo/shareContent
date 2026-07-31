#!/bin/bash

if [ $# -lt 6 ]; then
  echo "Usage: $0 <bin_dir> <db_user> <db_password> <db_host> <db_port> <key> [db_type(mysql|pg)]"
  exit
fi

BIN_PATH=$1
DB_USER=$2
DB_PASSWORD=$3
DB_HOST=$4
DB_PORT=$5
SEARCH_KEY=$6
DB_TYPE=${7:-pg}

if [ "$DB_TYPE" = "mysql" ]; then
  result=`$BIN_PATH/mysql -u$DB_USER -p$DB_PASSWORD -h$DB_HOST -P$DB_PORT delay_test -e"set autocommit=1;call wait_delay_test_key($SEARCH_KEY)" 2>&1`
elif [ "$DB_TYPE" = "pg" ]; then
  export PGPASSWORD=$DB_PASSWORD
  export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}
  WAIT_TIMEOUT_MS=${WAIT_TIMEOUT_MS:-60000}
  result=`$BIN_PATH/psql -h$DB_HOST -p$DB_PORT -U$DB_USER -d delay_test -t -A -v ON_ERROR_STOP=1 -c "SET statement_timeout = $WAIT_TIMEOUT_MS; SELECT wait_delay_test_key($SEARCH_KEY)" 2>&1`
else
  echo "Unsupported db_type: $DB_TYPE (use mysql or pg)"
  exit 1
fi

if [ $? -eq 0 ]; then
  t=`date +%s%N | cut -c1-13`
  echo $result | grep $SEARCH_KEY
  if [ $? -eq 0 ]; then
    echo "$SEARCH_KEY $t" >> ${DB_HOST}_${DB_PORT}_delay.result
    exit
  fi
else
  echo "$SEARCH_KEY $result" >> ${DB_HOST}_${DB_PORT}_delay.result
  exit
fi
