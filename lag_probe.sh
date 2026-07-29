#!/bin/bash
# lag_probe.sh —— 复制延迟探针（握手式，融进 perf 单并发点 sweep）。
#
# 被 lag_probe_lib.sh 的 start_lag_probe 后台 fork 调用，与同一并发点的压测 run
# 时间重叠：压测前台阻塞跑，本脚本后台同时跑握手循环。
#
# 口径（不变）：lag = t_replica - t_master，两端客户端 date +%s%N 截 ms 打戳。
#   每 key：先对备机后台 fork lag_check.sh（busy-wait wait_delay_test_key
#   等行出现）→ 主库 INSERT 该 key → 客户端打 t_master。lag_check 拿到行
#   后打 t_replica。lag_stats.sh join 两端按 label 算 nearest-rank 百分位。
#
# 与原 /root/replica_lag 版差异（融 perf 用）：
#   - 不建独立库 delay_test；marker 表 test + 函数 wait_delay_test_key 直接建在
#     perf 传入的 db_name 库（库已 prepare、GRANT ALL ON SCHEMA public 已执行）。
#   - 不读 server_list；主备 IP 由参数传入（主=perf spec_ip，备=ip_${spec}_slave1）。
#   - deadline 截止循环替代 for 1..KEY_COUNT（对齐 sysbench sweep 时长，硬停）。
#   - 结果文件按 label 切名（label=${perf_mode}_t${threads}），落 out_dir。
#   - 每点 sweep 开始前 TRUNCATE test（清上点残留、key 重置回 1）。
#   - 删 run.sh 编排；改由 pg_perf.sh 调用。仅 pg。
#
# 用法（由 lag_probe_lib.sh start_lag_probe 构造）：
#   lag_probe.sh <bin> <user> <passwd> <master_ip> <master_port> \
#     <slave_ip> <slave_port> <db_name> <deadline_epoch> <sleep_interval> \
#     <label> <out_dir> [wait_timeout_ms]
set -uo pipefail

if [ $# -lt 12 ]; then
  echo "Usage: $0 <bin> <user> <passwd> <master_ip> <master_port> <slave_ip> <slave_port> <db_name> <deadline_epoch> <sleep_interval> <label> <out_dir> [wait_timeout_ms]"
  exit 1
fi

BIN_PATH=$1
DB_USER=$2
DB_PASSWORD=$3
MASTER_HOST=$4
MASTER_PORT=$5
SLAVE_HOST=$6
SLAVE_PORT=$7
DB_NAME=$8
DEADLINE_EPOCH=$9
SLEEP_INTERVAL=${10}
LABEL=${11}
OUT_DIR=${12}
WAIT_TIMEOUT_MS=${13:-320000}

mkdir -p "$OUT_DIR"

# marker 表 + busy-wait 函数直接建在 db_name（库已 prepare、public 已 GRANT）。
# 幂等：CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE FUNCTION，--no-clean 重跑安全。
export PGPASSWORD=$DB_PASSWORD
PSQL="$BIN_PATH/psql"
PG_OPTS="-h $MASTER_HOST -p $MASTER_PORT -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1"

$PSQL $PG_OPTS <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS test (i int primary key);

CREATE OR REPLACE FUNCTION wait_delay_test_key(search_key int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  k int := -1;
BEGIN
  -- IS DISTINCT FROM (not <>) so NULL (row not yet replicated) is treated as
  -- "not equal" and the loop keeps busy-waiting. With <>, NULL <> search_key
  -- evaluates to NULL (falsy) and the loop exits immediately.
  WHILE k IS DISTINCT FROM search_key LOOP
    SELECT i INTO k FROM test WHERE i = search_key;
  END LOOP;
  RETURN k;
END;
$$;
SQL
if [ $? -ne 0 ]; then
  echo "[lag] 建表/函数失败（master=$MASTER_HOST db=$DB_NAME）" >&2
  exit 1
fi

# 函数复制到备机需要沉淀；首点尤其要等（函数刚建）。轮询直到备机能调用它。
# 比固定 sleep 10 更稳：lag 大时也能等到，无 lag 时秒过。
probe_ok=0
for _ in $(seq 1 60); do
  if $PSQL -h "$SLAVE_HOST" -p "$SLAVE_PORT" -U "$DB_USER" -d "$DB_NAME" \
      -t -A -c "SELECT 1 FROM pg_proc WHERE proname='wait_delay_test_key'" 2>/dev/null | grep -q 1; then
    probe_ok=1; break
  fi
  sleep 1
done
[ "$probe_ok" = "1" ] || echo "[lag] 警告: 备机 $SLAVE_HOST 60s 内未见函数复制到，早期 key 可能报错" >&2

# 清上点残留（key 重置回 1）。注意：调用方 start/stop_lag_probe 保证上点 lag_check
# 进程组已被杀净，此处 TRUNCATE 不会被残留 busy-wait 的 AccessShareLock 阻塞。
$PSQL $PG_OPTS -c "TRUNCATE TABLE test;" >/dev/null 2>&1 || true

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MASTER_FILE="$OUT_DIR/master_insert_${LABEL}.time"

# deadline 截止循环：跑到 sysbench sweep 结束时刻硬停，对齐 sweep 时长。
key=1
while [ "$(date +%s)" -lt "$DEADLINE_EPOCH" ]; do
  # 先 fork 备机轮询（此时行还不存在，它 busy-wait 等这一行出现）
  sh "$SCRIPT_DIR/lag_check.sh" "$BIN_PATH" "$DB_USER" "$DB_PASSWORD" \
     "$SLAVE_HOST" "$SLAVE_PORT" "$DB_NAME" "$key" "$LABEL" "$OUT_DIR" "$WAIT_TIMEOUT_MS" &

  # 主库 INSERT 该 key（行提交后，备机轮询函数陆续看到并返回）
  result=$($PSQL $PG_OPTS -c "INSERT INTO test VALUES($key)" 2>&1)
  if [ $? -ne 0 ]; then
    echo "[lag] INSERT key=$key 失败: $result" >&2
  fi

  # 客户端打 t_master（INSERT 返回之后；同机房两端同机打戳，偏差可忽略）
  t=$(date +%s%N | cut -c1-13)
  echo "$key $t" >> "$MASTER_FILE"

  key=$((key + 1))
  sleep "$SLEEP_INTERVAL"
done

# 收尾所有后台 lag_check（超时的会被 statement_timeout 杀、记 TIMEOUT 行）
wait
