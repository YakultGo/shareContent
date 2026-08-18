#!/bin/bash
# ==============================================================================
# 脚本名称: run_stepped_tpch_console.sh
# 说明: TPC-H 阶梯性能压测脚本 (仅记录精确时间段与 TPS，便于 AWS 控制台对照)
# ==============================================================================

# ----------------- 1. 基础配置 -----------------
SERVER_IP="192.168.0.30"
DB_PORT="5432"
DB_USER="root"
DB_NAME="tpchtest"
export PGPASSWORD="Huawei@234"

HAMMERDB_DIR="/root/HammerDB-6.0"
TCL_SCRIPT="/root/scheduled_rds_test.tcl"

# 17 个并发阶梯 (VU)
VU_LIST=(1 2 4 6 8 10 12 14 16 18 20 24 28 32 36 48 64)

# 压测时长: 1500 秒 (25 分钟) | 冷却时长: 300 秒 (5 分钟)
DURATION=1500
COOL_DOWN=300

RESULT_FILE="tpch_benchmark_result.txt"

# ----------------- 2. 初始化 -----------------
cd $HAMMERDB_DIR || { echo "错误: 找不到目录 $HAMMERDB_DIR"; exit 1; }

# 表头只保留 VU、时间段和 TPS
echo -e "VU\tStartTime\tEndTime\tRDS TPS" > $RESULT_FILE

echo "=================================================================="
echo " 开始 TPC-H 顺序阶梯性能测试"
echo " 单阶梯时长 : ${DURATION}s (25分钟) | 阶梯冷却: ${COOL_DOWN}s (5分钟)"
echo " 结果将记录测试时间段，后续可直接在 AWS RDS 控制台框选查看 CPU"
echo "=================================================================="

# ----------------- 3. 遍历测试 -----------------
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
    timeout $DURATION ./hammerdbcli tcl auto $TCL_SCRIPT > /dev/null 2>&1

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

    # ④ 打印并记录结果
    echo "[$END_TIME] <<< VU=$vu 完成 | 时间段: [$START_TIME ~ $END_TIME] | TPS: $TPS"
    echo -e "${vu}\t${START_TIME}\t${END_TIME}\t${TPS}" >> $RESULT_FILE

    # ⑤ 冷却 5 分钟
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 进入冷却阶段 (${COOL_DOWN}s)..."
    sleep $COOL_DOWN
done

echo "=================================================================="
echo " 所有测试已完成！"
echo " 最终测试日志存入: $HAMMERDB_DIR/$RESULT_FILE"
echo "=================================================================="
cat $RESULT_FILE
