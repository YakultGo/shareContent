#!/bin/bash
# lag_run.sh —— Aurora PG 复制延迟测量。与 lag_stats.sh 配套。
# 用法: lag_run.sh <writer_ip> <reader_ip> -U <user> -W <pwd> -d <db> -p 5432 -D 300
#   跑满 -D 秒（默认 300）后自动算 P50/P90/P95/P99；过程日志 ./lag_out/lag_run_<label>.log。
#   Aurora SSL: export PGPASSWORD=... PGSSLMODE=require（psql 读环境变量，脚本不改）。
#   sysbench 在另一窗口自己跑，这边只测延迟。简写: lag_run.sh <master> <slave> [-D 秒]
set -uo pipefail

usage() {
    cat <<'EOF'
用法: lag_run.sh <master_ip> <slave_ip> [-D 秒] [选项]
      lag_run.sh -M <master_ip> -S <slave_ip> [选项]
必填: master(writer) IP 和 slave(reader) IP
选项:
  -p, --port PORT       主备同端口（默认 5432）
      --mport PORT       主机端口（默认同 --port）
      --sport PORT       备机端口（默认同 --port）
  -U, --user USER        PG 用户（默认 $PGUSER 或 postgres）
  -W, --password PWD     PG 密码（默认 $PGPASSWORD）
  -d, --db DB            库名（默认 $PGDATABASE 或 postgres）
  -i, --interval SEC     每 key 间隔秒（默认 0.5）
  -t, --timeout MS       单 key 等待超时 ms（默认 320000）
  -L, --label LABEL      标签（默认 lag_<pid>）
  -o, --outdir DIR       输出目录（默认 ./lag_out）
  -D, --duration SEC     测量持续秒数（默认 300，对齐 sysbench）
  -h, --help
EOF
}

# 默认值
MASTER=""; SLAVE=""
PORT=5432; MPORT=""; SPORT=""
DB_USER="${PGUSER:-postgres}"
DB_PASS="${PGPASSWORD:-}"
DB_NAME="${PGDATABASE:-postgres}"
INTERVAL=0.5
TIMEOUT_MS=320000
LABEL="lag_$$"
OUTDIR="./lag_out"
DURATION=300

# 解析参数
while [ $# -gt 0 ]; do
    case "$1" in
        -M|--master)   MASTER="$2";  shift 2;;
        -S|--slave)    SLAVE="$2";   shift 2;;
        -p|--port)     PORT="$2";    shift 2;;
        --mport)       MPORT="$2";  shift 2;;
        --sport)       SPORT="$2";  shift 2;;
        -U|--user)     DB_USER="$2"; shift 2;;
        -W|--password) DB_PASS="$2"; shift 2;;
        -d|--db)       DB_NAME="$2"; shift 2;;
        -i|--interval) INTERVAL="$2"; shift 2;;
        -t|--timeout)  TIMEOUT_MS="$2"; shift 2;;
        -L|--label)    LABEL="$2";  shift 2;;
        -o|--outdir)   OUTDIR="$2"; shift 2;;
        -D|--duration) DURATION="$2"; shift 2;;
        -h|--help)     usage; exit 0;;
        --) shift; break;;
        -*) echo "未知选项: $1" >&2; usage; exit 2;;
        *)
            if   [ -z "$MASTER" ]; then MASTER="$1"
            elif [ -z "$SLAVE" ];  then SLAVE="$1"
            else echo "多余位置参数: $1" >&2; exit 2; fi
            shift;;
    esac
done

[ -n "$MASTER" ] && [ -n "$SLAVE" ] || { echo "错误: 需指定 master 和 slave IP（lag_run.sh <master> <slave>）" >&2; usage; exit 2; }
[ -n "$MPORT" ] || MPORT="$PORT"
[ -n "$SPORT" ] || SPORT="$PORT"

BIN="$(dirname "$(command -v psql)")"
[ -n "$BIN" ] || { echo "错误: 找不到 psql（PG 客户端未装或不在 PATH）" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUTDIR"

LOG="$OUTDIR/lag_run_${LABEL}.log"
MASTER_FILE="$OUTDIR/master_insert_${LABEL}.time"
DELAY_FILE="$OUTDIR/${SLAVE}_${SPORT}_${LABEL}_delay.result"
STATS_TXT="$OUTDIR/lag_${LABEL}.txt"
DEADLINE=$(( $(date +%s) + DURATION ))
export PGPASSWORD="$DB_PASS"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"

say() { echo "$*" | tee -a "$LOG"; }

# 单 key 备机握手（fork 后台子 shell）：busy-wait 等该 key 出现，拿到后打 t_replica 并算 lag 写日志
lag_check_one() {  # $1=key
    local key=$1 rc result t_replica t_master lag
    result=$("$BIN"/psql -h"$SLAVE" -p"$SPORT" -U"$DB_USER" -d"$DB_NAME" \
        -t -A -v ON_ERROR_STOP=1 \
        -c "SET statement_timeout = $TIMEOUT_MS; SELECT wait_lag_test_key($key)" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        t_replica=$(date +%s%N | cut -c1-13)
        echo "$key $t_replica" >> "$DELAY_FILE"
        t_master=$(awk -v k="$key" '$1==k{print $2}' "$MASTER_FILE" 2>/dev/null | tail -1)
        if [ -n "$t_master" ]; then
            lag=$(( t_replica - t_master )); [ "$lag" -lt 0 ] && lag=0
            echo "[lag] key=$key lag=${lag}ms"
        fi
    else
        echo "$key TIMEOUT" >> "$DELAY_FILE"
        echo "[lag] key=$key TIMEOUT"
    fi
}

# 建表/函数 + 等备机函数复制到 + 清残留
setup() {
    local PSQL="$BIN/psql"
    local PG_OPTS="-h $MASTER -p $MPORT -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1"
    "$PSQL" $PG_OPTS <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS lag_test (i int primary key);
CREATE OR REPLACE FUNCTION wait_lag_test_key(search_key int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE k int := -1;
BEGIN
  WHILE k IS DISTINCT FROM search_key LOOP
    SELECT i INTO k FROM lag_test WHERE i = search_key;
  END LOOP;
  RETURN k;
END;
$$;
SQL
    if [ $? -ne 0 ]; then
        say "[lag_run] 建表/函数失败（master=$MASTER:$MPORT db=$DB_NAME）"
        exit 1
    fi
    local ok=0 _
    for _ in $(seq 1 60); do
        if "$PSQL" -h "$SLAVE" -p "$SPORT" -U "$DB_USER" -d "$DB_NAME" \
            -t -A -c "SELECT 1 FROM pg_proc WHERE proname='wait_lag_test_key'" 2>/dev/null | grep -q 1; then
            ok=1; break
        fi
        sleep 1
    done
    [ "$ok" = "1" ] || say "[lag_run] 警告: 备机 $SLAVE:$SPORT 60s 内未见函数复制到，早期 key 可能报错"
    "$PSQL" $PG_OPTS -c "TRUNCATE TABLE lag_test;" >/dev/null 2>&1 || true
}

# 收尾 + 调 lag_stats
report() {
    [ -n "${COUNTER_PID:-}" ] && kill "$COUNTER_PID" 2>/dev/null
    wait 2>/dev/null   # 等在飞的子 shell 收尾
    say
    say "[lag_run] 测量结束，调用 lag_stats.sh 计算百分位..."
    if [ ! -f "$MASTER_FILE" ] || [ ! -f "$DELAY_FILE" ]; then
        say "[lag_run] 无样本文件，无法统计（master=$MASTER_FILE delay=$DELAY_FILE）"
        say "[lag_run] 探针日志见 $LOG"
        exit 1
    fi
    echo
    say "===== 复制延迟统计 (label=$LABEL) ====="
    bash "$SCRIPT_DIR/lag_stats.sh" "$MASTER_FILE" "$DELAY_FILE" "$STATS_TXT" 2>&1 | tee -a "$LOG"
    say "========================================"
    say "[lag_run] 明细: $MASTER_FILE / $DELAY_FILE"
    say "[lag_run] 统计: $STATS_TXT   日志: $LOG"
    exit 0
}

say "[lag_run] $(date '+%Y-%m-%d %H:%M:%S') 启动"
say "[lag_run] master=$MASTER:$MPORT slave=$SLAVE:$SPORT db=$DB_NAME user=$DB_USER"
say "[lag_run] interval=${INTERVAL}s timeout=${TIMEOUT_MS}ms duration=${DURATION}s label=$LABEL"
say "[lag_run] 日志: $LOG"
say "[lag_run] 正在测量复制延迟... ${DURATION}s 后自动统计"

setup

# 采样进度进日志（每 5s）
( while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      sleep 5
      [ -f "$MASTER_FILE" ] && n=$(wc -l < "$MASTER_FILE" 2>/dev/null || echo 0) || n=0
      echo "$(date '+%H:%M:%S') running  samples=${n}" >> "$LOG"
  done ) & COUNTER_PID=$!

# 探针主循环
key=1
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    lag_check_one "$key" >> "$LOG" 2>&1 &      # fork 备机轮询，输出进日志
    "$BIN"/psql -h"$MASTER" -p"$MPORT" -U"$DB_USER" -d"$DB_NAME" \
        -v ON_ERROR_STOP=1 -c "INSERT INTO lag_test VALUES($key)" >/dev/null 2>&1 \
        || say "[lag_run] INSERT key=$key 失败"
    t=$(date +%s%N | cut -c1-13)               # 打 t_master
    echo "$key $t" >> "$MASTER_FILE"
    key=$((key + 1))
    sleep "$INTERVAL"
done

report
