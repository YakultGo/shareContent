#create an user, example:
#mysql> create user 'repl'@'%' identified with mysql_native_password by '123456';
#mysql> GRANT ALL ON *.* TO  'repl'@'%' WITH GRANT OPTION;
#mysql>  FLUSH PRIVILEGES;
#
#for Taurus PG, create role & grant (note: PG replication is handled by the
#standby's primary_conninfo; the test only needs a login role on the db):
#  CREATE ROLE repl WITH LOGIN PASSWORD '123456';
#  GRANT ALL ON DATABASE delay_test TO repl;

SQLDIST=/mnt/ssd1/hylee/TaurusPG/install
SQL_BIN=${SQLDIST}/bin
export LD_LIBRARY_PATH=${SQLDIST}/lib:$LD_LIBRARY_PATH
# for pg, also expose the password to psql via PGPASSWORD
export PGPASSWORD=Letmein123
export KEY_COUNT=${KEY_COUNT:-7000}
export SLEEP_INTERVAL=${SLEEP_INTERVAL:-0.02}
rm *.result
#Usage: $0 <bin_dir> <server_list_file> <db_user> <db_password> [db_type(mysql|pg)]
./replica_delay_test.sh ${SQL_BIN} /mnt/ssd1/hylee/TaurusPG/tools_scripts/replica/server_list eboctor Letmein123 pg
./sum2.sh
