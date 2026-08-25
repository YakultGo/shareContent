#!/bin/bash
# run_benchmark_rw_ro.sh
# 比 run_benchmark.sh 多一步：先往 BIG_DB 预制 1TB(100表×5000万) 数据，单独放一个库、
# 之后不动；正式测试再往 TEST_DB 新导入 250表×100万，写512(读写混合) ⊕ 只读64(只读)
# 同时压 30 分钟，并全程记录复制延迟。1TB 库只在旁边让实例带着大库跑（真实场景）。
#
# 数据集说明：
#   BIG_DB  = 100 表 × 5000万行 = 50亿行 ≈ 1TB   （预制一次，永不 drop）
#   TEST_DB = 250 表 × 100万行 = 2.5亿行          （每次正式测试新导入；run 时 sysbench 打它）
#
# 用法:
#   ./run_benchmark_rw_ro.sh             # 默认 all：prepare(导1TB) → run(测试) 串行一次跑完
#   ./run_benchmark_rw_ro.sh all          # 同上
#   ./run_benchmark_rw_ro.sh prepare      # 只导 1TB 到 BIG_DB（一次性；想单独先备大库时用）
#   ./run_benchmark_rw_ro.sh run          # 只测试（TEST_DB 导 250×100万 + 预热 + 写512/只读64 + lag）；BIG_DB 复用不重导

# ================= 配置区 =================
PG_HOST="192.168.200.242"        # 集群 endpoint(VIP，指向主)
WRITER_HOST="192.168.200.53"     # 主机(primary)
READER_HOST="192.168.200.48"     # 备机(standby)
PG_PORT="5432"
PG_USER="root"
PG_PASS="Taurus_123"

# --- 1TB 大库（预制一次，不动）---
BIG_DB="sbtest1tb"
BIG_TABLES=100
BIG_TABLE_SIZE=50000000        # 5000万 × 100 = 50亿 ≈ 1TB
BIG_PREPARE_THREADS=100         # 并发受表数限制：100 表最多 100 线程，再多没用

# --- 测试库（每次正式测试新导入）---
TEST_DB="sbtest"
TEST_TABLES=250
TEST_TABLE_SIZE=1000000         # 100万 × 250 = 2.5亿
TEST_PREPARE_THREADS=128

# --- 并发与时长 ---
RW_THREADS=512                  # 写节点：读写混合并发（打 writer / TEST_DB）
RO_THREADS=64                   # 只读节点：只读并发（打 reader / TEST_DB）
TIME=1800                       # 正式测试 30 分钟
LAG_TIME=1800                   # lag 监测时长，对齐 sysbench（lag 内部 sleep 15 跳爬坡）

# --- 预热：只读负载打 writer，把热页进 buffer pool ---
WARMUP_THREADS=64
WARMUP_TIME=120

# --- sysbench 脚本（本地副本，与 run_benchmark.sh 一致；sysbench 装在 EC2 上）---
SB_RW="oltp_read_write.lua"
SB_RO="oltp_read_only.lua"
SB_PREP="oltp_common.lua"
# 只读负载额外参数：只点查、不开事务（与 run_benchmark.sh 的 ro 场景一致）
RO_EXTRA=(--range_selects=0 --skip-trx=1)

# 是否重新导入 TEST_DB（1=每次 run 都 drop/create+prepare TEST_DB；0=复用已有 TEST_DB，只压测）
RELOAD_TEST_DATA="${RELOAD_TEST_DATA:-1}"

LOG_LABEL="t${TEST_TABLES}_${TEST_TABLE_SIZE}_rw${RW_THREADS}_ro${RO_THREADS}"
MODE="${1:-all}"
# ===========================================

export PGPASSWORD="${PG_PASS}"
trap 'kill $(jobs -p) 2>/dev/null' EXIT

# 导完数据靠 sleep 30 落定即可（Aurora 共享存储，reader 秒级可见，不做复制追平门控）

# ---------- 重建库 ----------
recreate_db() {
    local db="$1"
    echo "--> 使用 WITH (FORCE) 强制清理并重建数据库: ${db}"
    psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${db} WITH (FORCE);"
    psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${db};"
}

# ============================================================
# 模式: prepare —— 一次性建 BIG_DB + 导 1TB + sleep 5 分钟让集群落定（比 run_benchmark.sh 多的流程）
# ============================================================
do_prepare() {
    echo "##############################################################"
    echo " 📦 PREPARE 1TB: ${BIG_TABLES}表 × ${BIG_TABLE_SIZE}行 = $((BIG_TABLES*BIG_TABLE_SIZE)) 行 ≈ 1TB -> ${BIG_DB}"
    echo "##############################################################"

    recreate_db "${BIG_DB}"

    echo "--> 导入 1TB 数据 (prepare)..."
    echo "+ sysbench --db-driver=pgsql --pgsql-host=${WRITER_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${BIG_DB} --tables=${BIG_TABLES} --table-size=${BIG_TABLE_SIZE} --threads=${BIG_PREPARE_THREADS} ./${SB_PREP} prepare"
    PREP_START=$(date +%s)
    echo "--> prepare 开始: $(date '+%Y-%m-%d %H:%M:%S')"
    sysbench --db-driver=pgsql \
      --pgsql-host="${WRITER_HOST}" \
      --pgsql-port="${PG_PORT}" \
      --pgsql-user="${PG_USER}" \
      --pgsql-password="${PG_PASS}" \
      --pgsql-db="${BIG_DB}" \
      --tables="${BIG_TABLES}" \
      --table-size="${BIG_TABLE_SIZE}" \
      --threads="${BIG_PREPARE_THREADS}" \
      ./"${SB_PREP}" prepare 2>&1 | tee "sysbench_1tb_prepare.log"
    PREP_END=$(date +%s)
    echo "--> prepare 结束: $(date '+%Y-%m-%d %H:%M:%S')  耗时 $(( PREP_END - PREP_START ))s"

    echo "--> ☕ 1TB 导入完成，休息 5 分钟让集群落定..."
    sleep 300
    echo "🎉 PREPARE 完成：1TB 已在 ${BIG_DB}（单库，不动）。"
}

# ============================================================
# 模式: run —— 正式测试：导 250×100万 + 预热 + 写512/只读64 同时 + lag
# ============================================================
do_run() {
    echo "##############################################################"
    echo " 🚀 RUN: 写${RW_THREADS}并发(读写混合) ⊕ 只读${RO_THREADS}并发(只读) | ${TIME}s | TEST_DB=${TEST_DB} (BIG_DB=${BIG_DB} 旁观)"
    echo "##############################################################"

    # 0. 新导入测试数据 250×100万 到 TEST_DB（要干净重测就换个 TEST_DB 名；1TB 的 BIG_DB 不碰）
    if [ "${RELOAD_TEST_DATA}" = "1" ]; then
        recreate_db "${TEST_DB}"
        echo "--> 导入测试数据 ${TEST_TABLES}表 × ${TEST_TABLE_SIZE}行 (prepare)..."
        echo "+ sysbench --db-driver=pgsql --pgsql-host=${WRITER_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${TEST_DB} --tables=${TEST_TABLES} --table-size=${TEST_TABLE_SIZE} --threads=${TEST_PREPARE_THREADS} ./${SB_PREP} prepare"
        PREP_START=$(date +%s)
        echo "--> prepare 开始: $(date '+%Y-%m-%d %H:%M:%S')"
        sysbench --db-driver=pgsql \
          --pgsql-host="${WRITER_HOST}" \
          --pgsql-port="${PG_PORT}" \
          --pgsql-user="${PG_USER}" \
          --pgsql-password="${PG_PASS}" \
          --pgsql-db="${TEST_DB}" \
          --tables="${TEST_TABLES}" \
          --table-size="${TEST_TABLE_SIZE}" \
          --threads="${TEST_PREPARE_THREADS}" \
          ./"${SB_PREP}" prepare 2>&1 | tee "sysbench_${LOG_LABEL}_prepare.log"
        PREP_END=$(date +%s)
        echo "--> prepare 结束: $(date '+%Y-%m-%d %H:%M:%S')  耗时 $(( PREP_END - PREP_START ))s"
    else
        echo "--> RELOAD_TEST_DATA=0，复用已有 ${TEST_DB}（不重新导入）"
    fi

    # 1. 导数据后冷却（Aurora 共享存储，reader 秒级可见，不做追平门控）
    echo "--> ☕ 初始化完成，休息 30 秒后开始预热..."
    sleep 30
    echo ""

    # 2. 场景预热 (Warm-up) —— 只读负载打 writer，把热页加载进 buffer pool
    echo "--> 🧊 场景预热 (Warm-up): 只读 | 线程 ${WARMUP_THREADS} | 时长 ${WARMUP_TIME}s | db=${TEST_DB}"
    echo "+ sysbench --db-driver=pgsql --pgsql-host=${WRITER_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${TEST_DB} --tables=${TEST_TABLES} --table-size=${TEST_TABLE_SIZE} --threads=${WARMUP_THREADS} --time=${WARMUP_TIME} --percentile=95 --report-interval=10 --forced-shutdown ${RO_EXTRA[*]} ./${SB_RO} run"
    sysbench --db-driver=pgsql \
      --pgsql-host="${WRITER_HOST}" \
      --pgsql-port="${PG_PORT}" \
      --pgsql-user="${PG_USER}" \
      --pgsql-password="${PG_PASS}" \
      --pgsql-db="${TEST_DB}" \
      --tables="${TEST_TABLES}" \
      --table-size="${TEST_TABLE_SIZE}" \
      --threads="${WARMUP_THREADS}" \
      --time="${WARMUP_TIME}" \
      --percentile=95 \
      --report-interval=10 \
      --forced-shutdown \
      "${RO_EXTRA[@]}" \
      ./"${SB_RO}" run | tee "sysbench_${LOG_LABEL}_warmup.log"

    echo "--> ☕ 预热完成，休息 30 秒后开始正式压测..."
    sleep 30
    echo ""

    # 3. 同时启动 写/只读 sysbench + lag 监测（都打 TEST_DB）
    echo "=========================================================="
    echo " 🚀 正式压测: 写${RW_THREADS}并发(读写混合,writer) ⊕ 只读${RO_THREADS}并发(只读,reader) | 持续 ${TIME}s | db=${TEST_DB}"
    echo "=========================================================="

    # 3.1 后台启动延迟监控：子 shell 先 sleep 15s，跳过 sysbench 建连接/爬坡阶段
    #     （该阶段无负载压力，lag 探针此时会测到一堆虚假的低时延，拉偏统计），
    #     等真正开始打负载后再 exec 成 lag_run。lag_run 也打 TEST_DB。
    ( sleep 15; exec ./lag_run.sh "${WRITER_HOST}" "${READER_HOST}" \
      -L "${LOG_LABEL}" \
      -U "${PG_USER}" \
      -W "${PG_PASS}" \
      -d "${TEST_DB}" \
      -p "${PG_PORT}" \
      -D "${LAG_TIME}" ) &
    LAG_PID=$!
    echo "--> [监控 15s 后启动] PID: ${LAG_PID}，日志前缀: ${LOG_LABEL}"

    # 3.2 后台启动写节点：512 并发 读写混合（输出各自落盘，避免两个 sysbench 在 stdout 交叉）
    echo "+ sysbench --db-driver=pgsql --pgsql-host=${WRITER_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${TEST_DB} --tables=${TEST_TABLES} --table-size=${TEST_TABLE_SIZE} --threads=${RW_THREADS} --time=${TIME} --percentile=95 --report-interval=10 --forced-shutdown ./${SB_RW} run  -> sysbench_${LOG_LABEL}_rw.log"
    sysbench --db-driver=pgsql \
      --pgsql-host="${WRITER_HOST}" \
      --pgsql-port="${PG_PORT}" \
      --pgsql-user="${PG_USER}" \
      --pgsql-password="${PG_PASS}" \
      --pgsql-db="${TEST_DB}" \
      --tables="${TEST_TABLES}" \
      --table-size="${TEST_TABLE_SIZE}" \
      --threads="${RW_THREADS}" \
      --time="${TIME}" \
      --percentile=95 \
      --report-interval=10 \
      --forced-shutdown \
      ./"${SB_RW}" run > "sysbench_${LOG_LABEL}_rw.log" 2>&1 &
    RW_PID=$!

    # 3.3 后台启动只读节点：64 并发 只读（打 reader）
    echo "+ sysbench --db-driver=pgsql --pgsql-host=${READER_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${TEST_DB} --tables=${TEST_TABLES} --table-size=${TEST_TABLE_SIZE} --threads=${RO_THREADS} --time=${TIME} --percentile=95 --report-interval=10 --forced-shutdown ${RO_EXTRA[*]} ./${SB_RO} run  -> sysbench_${LOG_LABEL}_ro.log"
    sysbench --db-driver=pgsql \
      --pgsql-host="${READER_HOST}" \
      --pgsql-port="${PG_PORT}" \
      --pgsql-user="${PG_USER}" \
      --pgsql-password="${PG_PASS}" \
      --pgsql-db="${TEST_DB}" \
      --tables="${TEST_TABLES}" \
      --table-size="${TEST_TABLE_SIZE}" \
      --threads="${RO_THREADS}" \
      --time="${TIME}" \
      --percentile=95 \
      --report-interval=10 \
      --forced-shutdown \
      "${RO_EXTRA[@]}" \
      ./"${SB_RO}" run > "sysbench_${LOG_LABEL}_ro.log" 2>&1 &
    RO_PID=$!

    echo "--> [写] PID=${RW_PID}  [只读] PID=${RO_PID}  [监控] PID=${LAG_PID}"
    echo "--> 测试进行中 ${TIME}s ...（可 tail -f sysbench_${LOG_LABEL}_rw.log sysbench_${LOG_LABEL}_ro.log）"

    # 4. 等三者结束
    wait ${RW_PID}; RW_RC=$?
    wait ${RO_PID}; RO_RC=$?
    wait ${LAG_PID} 2>/dev/null

    # 5. 汇总输出
    echo ""
    echo "=========================================================="
    echo " ✅ 测试结束 | 写 exit=${RW_RC} | 只读 exit=${RO_RC}"
    echo "=========================================================="
    echo ""
    echo ">>> 写节点 (读写混合 ${RW_THREADS}并发) 吞吐:"
    grep -E "transactions:|queries:|ignored errors:|reconnects:" "sysbench_${LOG_LABEL}_rw.log" 2>/dev/null | tail -5
    echo ""
    echo ">>> 只读节点 (只读 ${RO_THREADS}并发) 吞吐:"
    grep -E "transactions:|queries:|ignored errors:|reconnects:" "sysbench_${LOG_LABEL}_ro.log" 2>/dev/null | tail -5
    echo ""
    echo ">>> 复制延迟统计:"
    cat "lag_out/lag_${LOG_LABEL}.txt" 2>/dev/null || echo "  (见 lag_out/ 下 ${LOG_LABEL} 相关文件)"
    echo ""
    echo ">>> 文件:"
    echo "    写节点 sysbench : sysbench_${LOG_LABEL}_rw.log"
    echo "    只读节点 sysbench: sysbench_${LOG_LABEL}_ro.log"
    echo "    复制延迟统计    : lag_out/lag_${LOG_LABEL}.txt  (明细 lag_out/*${LOG_LABEL}*)"
    echo "🎉 完成"
}

case "${MODE}" in
    all)     do_prepare; do_run ;;
    prepare) do_prepare ;;
    run)     do_run ;;
    *) echo "用法: $0 [all|prepare|run]（默认 all：先 prepare 1TB 再 run 测试，串行）"; exit 1 ;;
esac
