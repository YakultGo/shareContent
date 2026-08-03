#!/bin/bash

# ================= 配置区 =================
PG_HOST="database-1.cluster-cnq0s48cas7o.ap-southeast-1.rds.amazonaws.com"
PG_PORT="5432"
PG_USER="root"
PG_PASS="Taurus_123"
PG_DB="sbtest"

READER_HOST="database-1-instance-1-reader.cnq0s48cas7o.ap-southeast-1.rds.amazonaws.com"
WRITER_HOST="database-1-instance-1.cnq0s48cas7o.ap-southeast-1.rds.amazonaws.com"

TIME=300
# 复制延迟监控测量秒数（独立于 TIME）。sysbench --time=300 --forced-shutdown 实际跑到 ~315s 才停；
# 配合下方 sleep 15，lag 测量窗 = t15..t315，末尾正好对齐 sysbench 停止点。
LAG_TIME=300
WARMUP_THREADS=100
WARMUP_TIME=300
PREPARE_THREADS=100   # 64×10M 导数据慢，可调大（如 256）加速 prepare

# 要遍历的并发线程列表
THREADS_LIST=(1 16 64 256 512 1024)

# 要连续跑的数据量配置: 标签 / 表数 / 每表行数 / 显示名（四组数组按下标一一对应）
CONFIG_LABELS=(cache io)
CONFIG_TABLES=(250 64)
CONFIG_SIZES=(25000 10000000)
CONFIG_NAMES=("cache" "IO")

# 要串行跑的压测场景: 标签 / sysbench 脚本 / 显示名（三组数组按下标一一对应）
SCEN_LABELS=(ro wo rw)
SCEN_SCRIPTS=(oltp_read_only.lua oltp_write_only.lua oltp_read_write.lua)
SCEN_NAMES=("Read-Only 只读" "Write-Only 只写" "Read-Write 读写混合")
# ==========================================

# 设置 PostgreSQL 环境变量，免去 psql 命令行交互
export PGPASSWORD="${PG_PASS}"

# 确保脚本发生错误终止时能正常清理后台进程
trap 'kill $(jobs -p) 2>/dev/null' EXIT

for c in "${!CONFIG_LABELS[@]}"; do
    CONFIG_LABEL="${CONFIG_LABELS[$c]}"
    TABLES="${CONFIG_TABLES[$c]}"
    TABLE_SIZE="${CONFIG_SIZES[$c]}"
    CONFIG_NAME="${CONFIG_NAMES[$c]}"

    echo ""
    echo "##############################################################"
    echo " 📦 数据量配置: ${CONFIG_NAME} (${CONFIG_LABEL}) | tables=${TABLES} table_size=${TABLE_SIZE}"
    echo "##############################################################"

    for i in "${!SCEN_LABELS[@]}"; do
        SCEN_LABEL="${SCEN_LABELS[$i]}"
        SCEN_SCRIPT="${SCEN_SCRIPTS[$i]}"
        SCEN_NAME="${SCEN_NAMES[$i]}"

        # ro 测试用 --range_selects=0 --skip-trx=1（跟 dev 对齐：只点查、不开事务）；wo/rw 用默认
        if [ "${SCEN_LABEL}" = "ro" ]; then
            SCEN_EXTRA=(--range_selects=0 --skip-trx=1)
        else
            SCEN_EXTRA=()
        fi
        EXTRA_DISP="${SCEN_EXTRA[*]}"
        [ -n "${EXTRA_DISP}" ] && EXTRA_DISP=" ${EXTRA_DISP}"

        echo ""
        echo "=========================================================="
        echo " 🚀 进入场景: ${CONFIG_NAME} / ${SCEN_NAME} (${CONFIG_LABEL}_${SCEN_LABEL})"
        echo "=========================================================="

        # --------------------------------------------------
        # 步骤 0: 重建数据库、导数据 (prepare) —— 每个场景前都重来，保证干净起点
        # --------------------------------------------------
        echo "--> 1. 使用 WITH (FORCE) 强制清理并重建数据库: ${PG_DB}"
        # 使用 -c 分别执行，避免 psql 将它们包装在同一个事务块中
        psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "DROP DATABASE IF EXISTS ${PG_DB} WITH (FORCE);"
        psql -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" -d postgres -c "CREATE DATABASE ${PG_DB};"

        echo "--> 2. 导入数据 (prepare)..."
        echo "+ sysbench --db-driver=pgsql --pgsql-host=${PG_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${PG_DB} --tables=${TABLES} --table-size=${TABLE_SIZE} --threads=${PREPARE_THREADS} ./oltp_common.lua prepare"
        PREP_START=$(date +%s)
        echo "--> prepare 开始: $(date '+%Y-%m-%d %H:%M:%S')"
        sysbench --db-driver=pgsql \
          --pgsql-host="${PG_HOST}" \
          --pgsql-port="${PG_PORT}" \
          --pgsql-user="${PG_USER}" \
          --pgsql-password="${PG_PASS}" \
          --pgsql-db="${PG_DB}" \
          --tables="${TABLES}" \
          --table-size="${TABLE_SIZE}" \
          --threads="${PREPARE_THREADS}" \
          ./oltp_common.lua prepare
        PREP_END=$(date +%s)
        echo "--> prepare 结束: $(date '+%Y-%m-%d %H:%M:%S')  耗时 $(( PREP_END - PREP_START ))s"

        echo "--> ☕ 初始化完成！休息 30 秒后开始预热..."
        sleep 30
        echo ""

        # -- 场景预热: 只读负载把数据页加载进 buffer pool，消除首轮冷启动偏置
        #    只读不改数据，三个场景统一用它，保证起点一致
        echo "--> 🧊 场景预热 (Warm-up): ${SCEN_NAME} | 线程 ${WARMUP_THREADS} | 时长 ${WARMUP_TIME}s"
        echo "+ sysbench --db-driver=pgsql --pgsql-host=${PG_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${PG_DB} --tables=${TABLES} --table-size=${TABLE_SIZE} --threads=${WARMUP_THREADS} --time=${WARMUP_TIME} --percentile=95 --report-interval=10 --forced-shutdown --range_selects=0 --skip-trx=1 ./oltp_read_only.lua run"
        sysbench --db-driver=pgsql \
          --pgsql-host="${PG_HOST}" \
          --pgsql-port="${PG_PORT}" \
          --pgsql-user="${PG_USER}" \
          --pgsql-password="${PG_PASS}" \
          --pgsql-db="${PG_DB}" \
          --tables="${TABLES}" \
          --table-size="${TABLE_SIZE}" \
          --threads="${WARMUP_THREADS}" \
          --time="${WARMUP_TIME}" \
          --percentile=95 \
          --report-interval=10 \
          --forced-shutdown \
          --range_selects=0 \
          --skip-trx=1 \
          ./oltp_read_only.lua run

        echo "--> ☕ 预热完成，休息 30 秒后开始梯度压测..."
        sleep 30
        echo ""

        for THREADS in "${THREADS_LIST[@]}"; do
            echo "=========================================================="
            echo " 开始测试: ${CONFIG_NAME} / ${SCEN_NAME} | 并发数: ${THREADS} | 持续时长: ${TIME}s "
            echo "=========================================================="

            LOG_LABEL="${CONFIG_LABEL}_${SCEN_LABEL}_t${THREADS}"

            # 1. 后台启动延迟监控脚本：子 shell 先 sleep 15s，跳过 sysbench 建连接/爬坡阶段
            #    （该阶段无负载压力，lag 探针此时会测到一堆虚假的低时延，拉偏统计），
            #    等真正开始打负载后再 exec 成 lag_run。
            #    sleep 15 + LAG_TIME=300 → lag 跑到 t315，正好对齐 sysbench 强制停止点（300+15s）。
            ( sleep 15; exec ./lag_run.sh "${WRITER_HOST}" "${READER_HOST}" \
              -L "${LOG_LABEL}" \
              -U "${PG_USER}" \
              -W "${PG_PASS}" \
              -d "${PG_DB}" \
              -p "${PG_PORT}" \
              -D "${LAG_TIME}" ) &

            LAG_PID=$!
            echo "--> [监控 15s 后启动] PID: ${LAG_PID}，日志前缀: ${LOG_LABEL}"

            # 2. 前台运行 sysbench 压测，并将输出保存到本地日志文件
            echo "+ sysbench --db-driver=pgsql --pgsql-host=${PG_HOST} --pgsql-port=${PG_PORT} --pgsql-user=${PG_USER} --pgsql-password=*** --pgsql-db=${PG_DB} --tables=${TABLES} --table-size=${TABLE_SIZE} --threads=${THREADS} --time=${TIME} --percentile=95 --report-interval=10 --forced-shutdown${EXTRA_DISP} ./${SCEN_SCRIPT} run"
            sysbench --db-driver=pgsql \
              --pgsql-host="${PG_HOST}" \
              --pgsql-port="${PG_PORT}" \
              --pgsql-user="${PG_USER}" \
              --pgsql-password="${PG_PASS}" \
              --pgsql-db="${PG_DB}" \
              --tables="${TABLES}" \
              --table-size="${TABLE_SIZE}" \
              --threads="${THREADS}" \
              --time="${TIME}" \
              --percentile=95 \
              --report-interval=10 \
              --forced-shutdown \
              "${SCEN_EXTRA[@]}" \
              ./"${SCEN_SCRIPT}" run | tee "sysbench_${LOG_LABEL}.log"

            echo "--> [压测结束] ${SCEN_LABEL} 并发数 ${THREADS} 运行完毕。"

            # 3. 等待本轮监控完全结束
            wait ${LAG_PID} 2>/dev/null

            # 4. 冷却 30 秒
            echo "--> ☕ 休息 30 秒后进入下一轮..."
            sleep 30
            echo ""
        done

        # 场景间冷却 60 秒，让复制延迟/缓冲池恢复平稳
        echo "--> ☕ 场景 ${SCEN_NAME} 结束，休息 60 秒后进入下一场景..."
        sleep 60
    done

    # 配置间冷却
    echo "--> ☕ 配置 ${CONFIG_NAME} 全部场景结束，休息 60 秒后进入下一配置..."
    sleep 60
done

echo "🎉 所有流程（2 数据量 × 3 场景 × 6 并发，每场景前重建库/导数据/预热/梯度压测）已全部完成！"
