#!/bin/bash
# run_benchmarksql_tpcc.sh
# BenchmarkSQL 5.0 跑 TPC-C：1000 仓 / 导数 50 / 并发 384，打 Aurora cluster(writer)。
# 流程：建库+导数(一次) → 预热 5 分钟 → 正式 30 分钟。独立场景，不涉及只读/lag。

# ================= 配置区 =================
BENCHSQL_DIR="$HOME/benchmarksql-5.0"
RUN_DIR="${BENCHSQL_DIR}/run"

PG_HOST="192.168.200.242"   # 集群 endpoint(VIP，指向主)
PG_PORT="5432"
PG_USER="root"
PG_PASS="Taurus_123"
TPCC_DB="tpcc"                  # TPC-C 表所在的库（脚本会 drop/create）

WAREHOUSES=1000                 # 仓库数 = 数据量（1000 仓 ≈ 80-100GB）
LOAD_WORKERS=100                # 导数线程（按仓库分片，≤ warehouses 即可；100 比 50 快）
TERMINALS=384                   # 并发数
WARMUP_MINS=5                   # 预热时长
RUN_MINS=30                     # 正式时长

LABEL="tpcc_${WAREHOUSES}w_t${TERMINALS}"
# ===========================================

export PGPASSWORD="${PG_PASS}"

# 驱动：lib/postgres/postgresql-42.7.3.jar（手动已换好，支持 SCRAM + PG18）

echo "##############################################################"
echo " 📦 TPC-C: ${WAREHOUSES}仓 / 导数${LOAD_WORKERS} / 并发${TERMINALS} | 预热${WARMUP_MINS}分钟 + 正式${RUN_MINS}分钟 | db=${TPCC_DB} @ ${PG_HOST}"
echo "##############################################################"

# ---------- 生成 props：$1=文件 $2=runMins ----------
gen_props() {
    local f="$1" rm="$2"
    cat > "$f" <<EOF
db=postgres
driver=org.postgresql.Driver
conn=jdbc:postgresql://${PG_HOST}:${PG_PORT}/${TPCC_DB}
user=${PG_USER}
password=${PG_PASS}
warehouses=${WAREHOUSES}
loadWorkers=${LOAD_WORKERS}
terminals=${TERMINALS}
runTxnsPerTerminal=0
runMins=${rm}
limitTxnsPerMin=0
terminalWarehouseFixed=true
newOrderWeight=45
paymentWeight=43
orderStatusWeight=4
deliveryWeight=4
stockLevelWeight=4
resultDirectory=$(basename "$f" .props)_result_%tY-%tm-%td_%tH%tM%tS
#osCollectorScript=./misc/os_collector_linux.py
#osCollectorInterval=1
#osCollectorDevices=net_eth0 blk_sda
EOF
}

# --------------------------------------------------
# 1. 重建 TPC-C 库
# --------------------------------------------------
echo "--> 1. 重建库: ${TPCC_DB}"
psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${TPCC_DB} WITH (FORCE);"
psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${TPCC_DB};"

# --------------------------------------------------
# 2. 生成 props（正式用 + 预热用，仅 runMins 不同）
# --------------------------------------------------
gen_props "${RUN_DIR}/${LABEL}.props"        "${RUN_MINS}"     # 正式（build 也用它，build 不读 runMins）
gen_props "${RUN_DIR}/${LABEL}_warmup.props" "${WARMUP_MINS}"  # 预热
echo "--> props 已生成: ${LABEL}.props(正式/${RUN_MINS}min) + ${LABEL}_warmup.props(预热/${WARMUP_MINS}min)"

cd "${RUN_DIR}"

# --------------------------------------------------
# 3. 建表 + 导数（runDatabaseBuild）—— 1000 仓会比较久，只跑一次
# --------------------------------------------------
echo "--> 3. 建表 + 导数 (runDatabaseBuild)..."
BUILD_START=$(date +%s)
echo "--> build 开始: $(date '+%Y-%m-%d %H:%M:%S')"
./runDatabaseBuild.sh "${LABEL}.props" 2>&1 | tee "${LABEL}_build.log"
BUILD_RC=${PIPESTATUS[0]}
BUILD_END=$(date +%s)
echo "--> build 结束: $(date '+%Y-%m-%d %H:%M:%S')  耗时 $(( BUILD_END - BUILD_START ))s  rc=${BUILD_RC}"

if [ "${BUILD_RC}" -ne 0 ]; then
    echo "❌ build 失败 (rc=${BUILD_RC})，跳过。查 ${LABEL}_build.log"
    exit 1
fi

echo "--> ☕ 导数完成，休息 30 秒后开始预热..."
sleep 30
echo ""

# --------------------------------------------------
# 4. 预热 run（5 分钟 / 384 并发，同一份数据，只 warm buffer pool）
# --------------------------------------------------
echo "=========================================================="
echo " 🧊 预热压测: ${TERMINALS} 并发 / ${WARMUP_MINS} 分钟"
echo "=========================================================="
WU_START=$(date +%s)
./runBenchmark.sh "${LABEL}_warmup.props" 2>&1 | tee "${LABEL}_warmup.log"
WU_RC=${PIPESTATUS[0]}
WU_END=$(date +%s)
echo "--> 预热结束 耗时 $(( WU_END - WU_START ))s  rc=${WU_RC}"

echo "--> ☕ 预热完成，休息 10 秒后进入正式压测..."
sleep 10
echo ""

# --------------------------------------------------
# 5. 正式 run（30 分钟 / 384 并发）
# --------------------------------------------------
echo "=========================================================="
echo " 🚀 正式压测: ${TERMINALS} 并发 / ${RUN_MINS} 分钟"
echo "=========================================================="
RUN_START=$(date +%s)
echo "--> run 开始: $(date '+%Y-%m-%d %H:%M:%S')"
./runBenchmark.sh "${LABEL}.props" 2>&1 | tee "${LABEL}_run.log"
RUN_END=$(date +%s)
echo "--> run 结束: $(date '+%Y-%m-%d %H:%M:%S')  耗时 $(( RUN_END - RUN_START ))s"

# --------------------------------------------------
# 6. 汇总
# --------------------------------------------------
echo ""
echo "=========================================================="
echo " ✅ TPC-C 测试结束"
echo "=========================================================="
echo ">>> 正式跑吞吐 (tpmC / measured):"
grep -iE "tpmC|measured|throughput|transactions" "${LABEL}_run.log" 2>/dev/null | tail -10
echo ""
echo ">>> 文件:"
echo "    build 日志 : ${RUN_DIR}/${LABEL}_build.log"
echo "    预热日志   : ${RUN_DIR}/${LABEL}_warmup.log"
echo "    正式日志   : ${RUN_DIR}/${LABEL}_run.log"
echo "    结果目录   : ${RUN_DIR}/${LABEL}_result_*   (含 RT 直方图等明细)"
echo "🎉 完成"
