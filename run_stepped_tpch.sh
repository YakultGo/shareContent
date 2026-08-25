#!/bin/bash
# ==============================================================================
# 脚本名称: run_stepped_tpch.sh
# 说明: TPROC-H 一键导数据 + 顺序阶梯压测 (自动记录时间段，方便配合 AWS 控制台查看 CPU)
# ==============================================================================

# ----------------- 1. 基础环境配置 -----------------
SERVER_IP="192.168.200.242"   # 集群 endpoint(VIP，指向主)
DB_PORT="5432"
DB_USER="root"
DB_NAME="tpchtest"
export PGPASSWORD="Taurus_123"

# 自动定位当前脚本目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TCL_BUILD_SCRIPT="$SCRIPT_DIR/tpch_build.tcl"
TCL_TEST_SCRIPT="$SCRIPT_DIR/scheduled_rds_test.tcl"

# ----------------- 2. 阶梯与时长配置 -----------------
VU_LIST=(1 2 4 6 8 10 12 14 16 18 20 24 28 32 36 48 64)
DURATION=1500     # 25 分钟
COOL_DOWN=300     # 5 分钟冷却

RESULT_FILE="$SCRIPT_DIR/tpch_benchmark_result.txt"

# ----------------- 3. 前置校验 -----------------
if [ ! -f "./hammerdbcli" ]; then
    echo "错误: 请将本脚本放在 HammerDB 解压目录下运行 (未找到 ./hammerdbcli)"
    exit 1
fi

# ----------------- 步骤 0a: 重建 ${DB_NAME} 库（干净起点；HammerDB buildschema 不建库，需先建好）-----------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 重建数据库 ${DB_NAME}（drop + create）..."
psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME} WITH (FORCE);"
psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d postgres -c "CREATE DATABASE ${DB_NAME};"

# ----------------- 步骤 0: 构建数据库结构并导数据 -----------------
if [ -f "$TCL_BUILD_SCRIPT" ]; then
    echo "=================================================================="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始构建 TPROC-H 10GB 数据库结构与导入数据 (32 线程)..."
    echo "=================================================================="
    ./hammerdbcli auto "$TCL_BUILD_SCRIPT"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 数据导入完成！数据库进入 5 分钟静置期..."
    sleep 300
else
    echo "提示: 未在同目录下找到 tpch_build.tcl，跳过导数据步骤，直接进入阶梯压测。"
fi

# ----------------- 步骤 1: 阶梯压测 -----------------
echo -e "VU\tStartTime\tEndTime\tRDS TPS" > $RESULT_FILE

echo "=================================================================="
echo " 开始 TPROC-H 顺序阶梯性能测试"
echo " 单阶梯时长 : ${DURATION}s (25分钟) | 阶梯冷却: ${COOL_DOWN}s (5分钟)"
echo " 结果文件 : $RESULT_FILE"
echo "=================================================================="

for vu in "${VU_LIST[@]}"; do
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "------------------------------------------------------------------"
    echo "[$START_TIME] >>> 开始测试并发数 (VU): $vu"

    export server_ip=$SERVER_IP
    export vuser_count=$vu

    # ① 记录起始事务数
    START_TX=$(psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d $DB_NAME -Atc \
      "SELECT xact_commit + xact_rollback FROM pg_stat_database WHERE datname='$DB_NAME';" 2>/dev/null)

    # ② 运行 25 分钟 HammerDB 压测
    timeout $DURATION ./hammerdbcli tcl auto "$TCL_TEST_SCRIPT" > /dev/null 2>&1

    END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    # ③ 记录结束事务数并计算 TPS
    END_TX=$(psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d $DB_NAME -Atc \
      "SELECT xact_commit + xact_rollback FROM pg_stat_database WHERE datname='$DB_NAME';" 2>/dev/null)

    if [ -n "$END_TX" ] && [ -n "$START_TX" ] && [ "$START_TX" -gt 0 ]; then
        DIFF_TX=$((END_TX - START_TX))
        TPS=$(awk "BEGIN {printf \"%.2f\", $DIFF_TX / $DURATION}")
    else
        TPS="0.00"
    fi

    # ④ 记录时间段与 TPS
    echo "[$END_TIME] <<< VU=$vu 完成 | 时间段: [$START_TIME ~ $END_TIME] | TPS: $TPS"
    echo -e "${vu}\t${START_TIME}\t${END_TIME}\t${TPS}" >> $RESULT_FILE

    # ⑤ 冷却 5 分钟
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 数据库进入冷却阶段 (${COOL_DOWN}s)..."
    sleep $COOL_DOWN
done

echo "=================================================================="
echo " 所有测试已完成！测试汇总存入: $RESULT_FILE"
echo "=================================================================="
cat $RESULT_FILE
