#!/bin/bash

if [ $# -lt 4 ]; then
  echo "Usage: $0 <bin_dir> <list_file> <db_user> <db_password> [db_type(mysql|pg)]"
  echo "Env:   KEY_COUNT (default 100)   SLEEP_INTERVAL (default 5s)"
  exit
fi

BIN_PATH=$1
NODE_LIST_FILE=$2
DB_USER=$3
DB_PASSWORD=$4
DB_TYPE=${5:-pg}

if [ "$DB_TYPE" != "mysql" ] && [ "$DB_TYPE" != "pg" ]; then
  echo "Unsupported db_type: $DB_TYPE (use mysql or pg)"
  exit 1
fi

MASTER_HOST=10.193.241.75
MASTER_PORT=5432
if [ "$DB_TYPE" = "pg" ]; then
  MASTER_PORT=5432
fi
REPLICA_HOST_LIST=()
REPLICA_PORT_LIST=()
i=0
while read line
do
  arr=($line)
  if [ $i -eq 0 ]; then
    MASTER_HOST=${arr[0]}
    MASTER_PORT=${arr[1]}
  else
    REPLICA_HOST_LIST[$i]=${arr[0]}
    REPLICA_PORT_LIST[$i]=${arr[1]}
  fi
  ((i++))
done < $NODE_LIST_FILE
REPLICA_COUNT=$((i-1))

echo "db_type: $DB_TYPE"
echo "Master: $MASTER_HOST:$MASTER_PORT"
echo "Replica:"
echo ${REPLICA_HOST_LIST[@]}
echo ${REPLICA_PORT_LIST[@]}

if [ "$DB_TYPE" = "pg" ]; then
  export PGPASSWORD=$DB_PASSWORD
fi

if [ "$DB_TYPE" = "mysql" ]; then
  $BIN_PATH/mysql -u$DB_USER -p$DB_PASSWORD -h$MASTER_HOST -P$MASTER_PORT -e"create database delay_test"
  if [ $? -ne 0 ]; then
    echo "Failed to create database for test."
    exit 1
  fi

  $BIN_PATH/mysql -u$DB_USER -p$DB_PASSWORD -h$MASTER_HOST -P$MASTER_PORT -e"create table delay_test.test(i int primary key)"
  if [ $? -ne 0 ]; then
    echo "Failed to create table for test."
    exit 1
  fi

  $BIN_PATH/mysql -u$DB_USER -p$DB_PASSWORD -h$MASTER_HOST -P$MASTER_PORT delay_test << 'EOF'
DELIMITER $$

create procedure wait_delay_test_key
(in search_key int)
begin
  declare k int default -1;
  select i into k from delay_test.test where i=search_key;
  while k <> search_key do
  select i into k from delay_test.test where i=search_key;
  end while;
  select k;
end $$

DELIMITER ;
EOF
  if [ $? -ne 0 ]; then
    echo "Failed to create procedure for test."
    exit 1
  fi
else
  $BIN_PATH/psql -h $MASTER_HOST -p $MASTER_PORT -U $DB_USER -d postgres -c "DROP DATABASE IF EXISTS delay_test"
  $BIN_PATH/psql -h $MASTER_HOST -p $MASTER_PORT -U $DB_USER -d postgres -c "CREATE DATABASE delay_test"
  if [ $? -ne 0 ]; then
    echo "Failed to create database for test."
    exit 1
  fi
 
  $BIN_PATH/psql -h $MASTER_HOST -p $MASTER_PORT -U $DB_USER -d delay_test -c "grant select on all tables in schema public to repl_user;"

  $BIN_PATH/psql -h $MASTER_HOST -p $MASTER_PORT -U $DB_USER -d delay_test << 'EOF'
CREATE TABLE IF NOT EXISTS test (i int primary key);

CREATE OR REPLACE FUNCTION wait_delay_test_key(search_key int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  k int := -1;
BEGIN
  -- IS DISTINCT FROM (not <>) so that NULL (row not yet replicated) is
  -- treated as "not equal" and the loop keeps busy-waiting. With <>,
  -- NULL <> search_key evaluates to NULL (falsy) and the loop exits
  -- immediately -- a MySQL/PG porting difference (MySQL preserves the
  -- previous INTO value on no-row; PG sets it to NULL).
  WHILE k IS DISTINCT FROM search_key LOOP
    SELECT i INTO k FROM test WHERE i = search_key;
  END LOOP;
  RETURN k;
END;
$$;
EOF
  if [ $? -ne 0 ]; then
    echo "Failed to create function for test."
    exit 1
  fi
fi

sleep 10

KEY_COUNT=${KEY_COUNT:-100}
SLEEP_INTERVAL=${SLEEP_INTERVAL:-5}
echo "key_count: $KEY_COUNT  sleep_interval: ${SLEEP_INTERVAL}s"

for key in $(seq 1 $KEY_COUNT)
do
  for i in $(seq 1 $REPLICA_COUNT)
  do
    sh check_replica.sh $BIN_PATH $DB_USER $DB_PASSWORD ${REPLICA_HOST_LIST[$i]} ${REPLICA_PORT_LIST[$i]} $key $DB_TYPE &
  done

  if [ "$DB_TYPE" = "mysql" ]; then
    result=`$BIN_PATH/mysql -u$DB_USER -p$DB_PASSWORD -h$MASTER_HOST -P$MASTER_PORT -e"insert into delay_test.test values($key)" 2>&1`
  else
    result=`$BIN_PATH/psql -h$MASTER_HOST -p$MASTER_PORT -U$DB_USER -d delay_test -v ON_ERROR_STOP=1 -c "INSERT INTO test VALUES($key)" 2>&1`
  fi
  if [ $? -ne 0 ]; then
    echo "Insert data to master failed: $result"
  fi
  t=`date +%s%N | cut -c1-13`
  echo "$key $t" >> master_insert_time.result
  sleep $SLEEP_INTERVAL
done

echo "All keys inserted. Waiting for background check_replica.sh processes to finish..."
echo "  (each has a ${WAIT_TIMEOUT_MS:-60000}ms statement_timeout; stale ones will be killed)"

wait
echo "All background processes completed."

