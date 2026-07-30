导数据：

sysbench --db-driver=pgsql \
      --pgsql-host=192.168.138.38 --pgsql-port=5432 \
      --pgsql-user=root --pgsql-password=x \
      --pgsql-db=sbtest \
      --tables=250 --table-size=25000 \
      --threads=100 \
      ./oltp_common.lua prepare


只读 ro：

sysbench --db-driver=pgsql \
    --pgsql-host=192.168.154.32 --pgsql-port=5432 \
    --pgsql-user=root --pgsql-password=x \
    --pgsql-db=sbtest \
    --tables=250 --table-size=25000 \
    --threads=N --time=300 --percentile=95 \
    --report-interval=10 \
    --forced-shutdown \ 
    --range_selects=0 --skip-trx=1 \
    ./oltp_read_only.lua run
  
只写 wo：
  sysbench --db-driver=pgsql \
    --pgsql-host=192.168.154.32 --pgsql-port=5432 \
    --pgsql-user=root --pgsql-password=x \
    --pgsql-db=sbtest \
    --tables=250 --table-size=25000 \
    --threads=N --time=300 --percentile=95 \
    --report-interval=10 \
    --forced-shutdown \
    ./oltp_write_only.lua run

读写 rw：
sysbench --db-driver=pgsql \
    --pgsql-host=192.168.154.32 --pgsql-port=5432 \
    --pgsql-user=root --pgsql-password=x \
    --pgsql-db=sbtest \
    --tables=250 --table-size=25000 \
    --threads=N --time=300 --percentile=95 \
    --report-interval=10 \
    --forced-shutdown \ 
    ./oltp_read_write.lua run

