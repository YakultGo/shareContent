#!/bin/bash
# ==============================================================================
# 脚本名称: run_stepped_tpch.sh
# 说明: TPC-H 阶梯性能测试控制脚本 (自动获取同目录 TCL，记录时间段与 TPS)
# ==============================================================================

# ----------------- 1. 基础环境配置 -----------------
SERVER_IP="192.168.0.30"
DB_PORT="5432"
DB_USER="root"
DB_NAME="tpchtest"
export PGPASSWORD="Huawei@234"

# 自动获取脚本当前所在目录，确保同目录调用
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAMMERDB_DIR="/root/HammerDB-6.0"
TCL_SCRIPT="$SCRIPT_DIR/scheduled_rds_test.tcl"

# ----------------- 2. 阶梯与时长配置 -----------------
# 17 个并发阶梯 (VU)
VU_LIST=(1 2 4 6 8 10 12 14 16 18 20 24 28 32 36 48 64)

# 压测时长: 1500 秒 (25 分钟) | 冷却时长: 300 秒 (5 分钟)
DURATION=1500
COOL_DOWN=300

# 结果保存文件 (生成在当前目录下)
RESULT_FILE="$SCRIPT_DIR/tpch_benchmark_result.txt"

# ----------------- 3. 校验与初始化 -----------------
if [ ! -f "$TCL_SCRIPT" ]; then
    echo "错误: 未在同目录下找到 TCL 脚本: $TCL_SCRIPT"
    exit 1
fi

cd $HAMMERDB_DIR || { echo "错误: 找不到 HammerDB 目录 $HAMMERDB_DIR"; exit 1; }

# 初始化结果表头
echo -e "VU\tStartTime\tEndTime\tRDS TPS" > $RESULT_FILE

echo "=================================================================="
echo " 开始 TPC-H 顺序阶梯性能测试"
echo " 目标数据库 : $SERVER_IP:$DB_PORT ($DB_NAME)"
echo " 测试阶梯数 : ${#VU_LIST[@]} 个 (VU: ${VU_LIST[*]})"
echo " 单阶梯时长 : ${DURATION}s (25分钟) | 阶梯冷却: ${COOL_DOWN}s (5分钟)"
echo " 结果文件 : $RESULT_FILE"
echo "=================================================================="

# ----------------- 4. 循环阶梯测试 -----------------
for vu in "${VU_LIST[@]}"; do
    START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "------------------------------------------------------------------"
    echo "[$START_TIME] >>> 开始测试并发数 (VU): $vu"

    # 设置供 TCL 脚本读取的环境变量
    export server_ip=$SERVER_IP
    export vuser_count=$vu

    # ① 记录压测前数据库总事务数
    START_TX=$(psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d $DB_NAME -Atc \
      "SELECT xact_commit + xact_rollback FROM pg_stat_database WHERE datname='$DB_NAME';" 2>/dev/null)

    # ② 前台运行 HammerDB 压测 (超时 1500 秒后自动结束)
    timeout $DURATION ./hammerdbcli tcl auto $TCL_SCRIPT > /dev/null 2>&1

    END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    # ③ 记录压测后数据库总事务数并计算 TPS (全量 25 分钟平均)
    END_TX=$(psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d $DB_NAME -Atc \
      "SELECT xact_commit + xact_rollback FROM pg_stat_database WHERE datname='$DB_NAME';" 2>/dev/null)

    if [ -n "$END_TX" ] && [ -n "$START_TX" ] && [ "$START_TX" -gt 0 ]; then
        DIFF_TX=$((END_TX - START_TX))
        TPS=$(awk "BEGIN {printf \"%.2f\", $DIFF_TX / $DURATION}")
    else
        TPS="0.00"
    fi

    # ④ 记录时间段与 TPS 结果
    echo "[$END_TIME] <<< VU=$vu 完成 | 时间段: [$START_TIME ~ $END_TIME] | TPS: $TPS"
    echo -e "${vu}\t${START_TIME}\t${END_TIME}\t${TPS}" >> $RESULT_FILE

    # ⑤ 阶梯间冷却 5 分钟 (300 秒)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 数据库进入冷却阶段 (${COOL_DOWN}s)..."
    sleep $COOL_DOWN
done

echo "=================================================================="
echo " 所有阶梯测试已全部完成！"
echo " 最终测试日志存入: $RESULT_FILE"
echo "=================================================================="
cat $RESULT_FILE
