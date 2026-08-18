#!/bin/bash
# ==============================================================================
# 脚本名称: run_stepped_tpch.sh
# 说明: TPC-H 阶梯性能压测脚本 (1500s 压测 + 300s 冷却，无 warmup)
# ==============================================================================

# ----------------- 1. 基础配置 (根据实际环境调整) -----------------
SERVER_IP="192.168.0.30"
DB_PORT="5432"
DB_USER="root"
DB_NAME="tpchtest"
export PGPASSWORD="Huawei@234"

# HammerDB 与 TCL 脚本路径
HAMMERDB_DIR="/root/HammerDB-6.0"
TCL_SCRIPT="/root/scheduled_rds_test.tcl"

# ----------------- 2. 压测阶梯与时长配置 -----------------
# 17 个并发阶梯 (VU)
VU_LIST=(1 2 4 6 8 10 12 14 16 18 20 24 28 32 36 48 64)

# 压测时长: 1500 秒 (25 分钟) | 冷却时长: 300 秒 (5 分钟)
DURATION=1500
COOL_DOWN=300

# 结果保存文件
RESULT_FILE="tpch_benchmark_result.txt"

# ----------------- 3. 初始化与准备 -----------------
cd $HAMMERDB_DIR || { echo "错误: 找不到目录 $HAMMERDB_DIR"; exit 1; }

# 创建或清空结果文件标头
echo -e "VU\tCPU\tRDS TPS" > $RESULT_FILE

echo "=================================================================="
echo " 开始 TPC-H 顺序阶梯性能测试"
echo " 目标数据库 : $SERVER_IP:$DB_PORT ($DB_NAME)"
echo " 测试阶梯数 : ${#VU_LIST[@]} 个 (VU: ${VU_LIST[*]})"
echo " 单阶梯时长 : ${DURATION}s (25分钟) | 阶梯冷却: ${COOL_DOWN}s (5分钟)"
echo " 结果输出文件: $HAMMERDB_DIR/$RESULT_FILE"
echo "=================================================================="

# ----------------- 4. 遍历阶梯开始测试 -----------------
for vu in "${VU_LIST[@]}"; do
    echo "------------------------------------------------------------------"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] >>> 开始测试并发数 (VU): $vu"

    # 设置供 TCL 脚本读取的环境变量
    export server_ip=$SERVER_IP
    export vuser_count=$vu

    # ① 记录压测前的数据库总事务数 (Commit + Rollback)
    START_TX=$(psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d $DB_NAME -Atc \
      "SELECT xact_commit + xact_rollback FROM pg_stat_database WHERE datname='$DB_NAME';" 2>/dev/null)

    if [ -z "$START_TX" ]; then
        echo "警告: 无法连接到数据库获取初始事务数，请检查数据库配置与密码！"
        START_TX=0
    fi

    # ② 后台异步采集系统 CPU 利用率 (每 10 秒采样一次，持续 25 分钟)
    (
        cpu_sum=0
        count=0
        for ((i=0; i<$DURATION; i+=10)); do
            # 获取当前 CPU 使用率 (%)
            idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'.' -f1)
            if [ -n "$idle" ]; then
                used=$((100 - idle))
                cpu_sum=$((cpu_sum + used))
                count=$((count + 1))
            fi
            sleep 10
        done
        if [ $count -gt 0 ]; then
            echo $((cpu_sum / count)) > /tmp/avg_cpu.tmp
        else
            echo "0" > /tmp/avg_cpu.tmp
        fi
    ) &
    CPU_PID=$!

    # ③ 启动 HammerDB 压测 (达到 1500 秒后自动超时退出)
    timeout $DURATION ./hammerdbcli tcl auto $TCL_SCRIPT > /dev/null 2>&1

    # 等待 CPU 采样线程结束并获取平均 CPU%
    wait $CPU_PID
    AVG_CPU=$(cat /tmp/avg_cpu.tmp 2>/dev/null || echo "0")
    rm -f /tmp/avg_cpu.tmp

    # ④ 记录压测后的数据库总事务数并计算平均 TPS
    END_TX=$(psql -h $SERVER_IP -p $DB_PORT -U $DB_USER -d $DB_NAME -Atc \
      "SELECT xact_commit + xact_rollback FROM pg_stat_database WHERE datname='$DB_NAME';" 2>/dev/null)

    if [ -n "$END_TX" ] && [ "$START_TX" -gt 0 ]; then
        DIFF_TX=$((END_TX - START_TX))
        TPS=$(awk "BEGIN {printf \"%.2f\", $DIFF_TX / $DURATION}")
    else
        TPS="0.00"
    fi

    # ⑤ 打印本轮结果并写入文件
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] <<< VU=$vu 测试完成 | 平均 CPU: ${AVG_CPU}% | 平均 TPS: $TPS"
    echo -e "${vu}\t${AVG_CPU}%\t${TPS}" >> $RESULT_FILE

    # ⑥ 阶梯间冷却 5 分钟 (300 秒)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 数据库进入冷却阶段 (${COOL_DOWN}s)..."
    sleep $COOL_DOWN
done

echo "=================================================================="
echo " 所有阶梯测试已全部完成！"
echo " 最终测试数据已汇总存入: $HAMMERDB_DIR/$RESULT_FILE"
echo "=================================================================="
cat $RESULT_FILE
