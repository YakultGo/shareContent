#!/bin/bash
# lag_check.sh —— 单 key 备机握手探针（被 lag_probe.sh fork）。
#
# busy-wait wait_delay_test_key($key) 直到该行在备库可见，可见后客户端打
# t_replica。lag = t_replica - t_master（两端客户端同机打戳，同机房偏差可忽略）。
#
# 与原 /root/replica_lag 版差异（融 perf 用）：
#   - 连 perf 传入的 db_name（原硬编码 -d delay_test）。
#   - 结果文件带 label 后缀、落 out_dir：${slave}_${port}_${label}_delay.result。
#   - 超时右删失：被 statement_timeout 杀掉（lag>=wait_timeout）的 key 不再写
#     错误文本（统计时被丢、低估 P99），改写 "key TIMEOUT"，lag_stats.sh 按 320000ms
#     截断值计入百分位分布 + 单列超时率。
#   - 加固静默丢失：psql rc=0 时总是写 t_replica 行（原版依赖 grep key 匹配才写，
#     边界情况会既不写成功行也不写错误行，sum2 join 时悄悄丢这个 key）。
#   - 仅 pg（perf 框架只跑 pg）。
set -uo pipefail

if [ $# -lt 9 ]; then
  echo "Usage: $0 <bin_dir> <db_user> <db_password> <db_host> <db_port> <db_name> <key> <label> <out_dir> [wait_timeout_ms]"
  exit 1
fi

BIN_PATH=$1
DB_USER=$2
DB_PASSWORD=$3
DB_HOST=$4
DB_PORT=$5
DB_NAME=$6
SEARCH_KEY=$7
LABEL=$8
OUT_DIR=$9
WAIT_TIMEOUT_MS=${10:-320000}

export PGPASSWORD=$DB_PASSWORD
export PGCONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}

RESULT_FILE="$OUT_DIR/${DB_HOST}_${DB_PORT}_${LABEL}_delay.result"

# busy-wait 等行出现；statement_timeout 防 lag 极大时空转（右删失截断值）
result=$($BIN_PATH/psql -h"$DB_HOST" -p"$DB_PORT" -U"$DB_USER" -d"$DB_NAME" \
  -t -A -v ON_ERROR_STOP=1 \
  -c "SET statement_timeout = $WAIT_TIMEOUT_MS; SELECT wait_delay_test_key($SEARCH_KEY)" 2>&1)
rc=$?

if [ "$rc" -eq 0 ]; then
  # 成功：总是写 t_replica 行（不再依赖 grep key 匹配，防静默丢失）
  t=$(date +%s%N | cut -c1-13)
  echo "$SEARCH_KEY $t" >> "$RESULT_FILE"
  exit 0
else
  # 失败：超时（lag>=wait_timeout，右尾最大值）按右删失标记，sum2 计 320000 计入分布
  echo "$SEARCH_KEY TIMEOUT" >> "$RESULT_FILE"
  exit 0
fi
