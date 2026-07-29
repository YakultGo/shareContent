#!/bin/bash
# lag_probe_lib.sh —— 复制延迟旁路探针的库函数（sysbench / tpcc 共用）。
#
# 由 pg_perf.sh 和 pg_tpcc.sh source。提供 start_lag_probe / stop_lag_probe 等。
# 不依赖 sysbench 的 perf_mode/last_time——label 和 run_secs 由调用方传。
#
# 上下文变量（调用方需已设置）：PG_USER / PG_PASSWD / PG_PORT / pg_ip / db_name /
#   result_dirs / spec（用于查 ip_${spec}_lag_master / ip_${spec}_slave1）。
# lag_tool_dir 由本文件基于自身路径推导。

lag_tool_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 备机固定 IP（lag 读端）：ip_${spec}_slave1 原始值（空则空串→跳过 lag）
lag_slave_ip_for_spec() {  # $1=spec
    local v="ip_${1}_slave1"
    echo "${!v:-}"
}

# lag 主机端固定 IP：ip_${spec}_lag_master（空则回退该规格浮动 ip_${spec}，再空才 pg_ip）
lag_primary_ip_for_spec() {  # $1=spec
    local spec=$1
    local v="ip_${spec}_lag_master"
    local ip="${!v:-}"
    [ -n "$ip" ] || { local f="ip_${spec}"; ip="${!f:-}"; }
    [ -n "$ip" ] || ip="${pg_ip}"
    echo "$ip"
}

# start_lag_probe <threads> <slave_ip> <slave_port> <spec> <label> <run_secs>
# 后台起探针，与压测 run 同时跑；deadline = now + run_secs（对齐 sweep 时长）。
# 记 sweep 窗口 + slave_ip 到 window 文件，stop 读回（start/stop 两次调用，文件传递最稳）。
start_lag_probe() {
    local threads=$1 slave_ip=$2 slave_port=${3:-${PG_PORT}} spec=$4 label=$5 run_secs=$6
    local lag_out="${result_dirs}/lag"
    local master_ip
    master_ip=$(lag_primary_ip_for_spec "${spec}")
    mkdir -p "${lag_out}"
    local sweep_start_ms=$(date +%s%N | cut -c1-13)
    printf '%s %s %s\n' "${sweep_start_ms}" "${slave_ip}" "${slave_port}" > "${lag_out}/.${label}.window"
    local deadline=$(( $(date +%s) + run_secs + 5 ))
    export PGPASSWORD=${PG_PASSWD}
    # setsid 让探针成独立进程组，stop 时 kill -- -PGID 杀净含 fork 的 lag_check
    setsid bash "${lag_tool_dir}/lag_probe.sh" \
        "$(dirname "$(command -v psql)")" \
        "${PG_USER}" "${PG_PASSWD}" "${master_ip}" "${PG_PORT}" \
        "${slave_ip}" "${slave_port}" "${db_name}" \
        "${deadline}" "${LAG_SLEEP_INTERVAL:-0.5}" "${label}" "${lag_out}" \
        "${LAG_WAIT_TIMEOUT_MS:-320000}" \
        > "${lag_out}/probe_${label}.log" 2>&1 &
    LAG_PID=$!   # 全局，stop_lag_probe（同 shell 顺序调用）读它杀进程组
    log "INFO" "[lag] 探针启动 label=${label} master=${master_ip} slave=${slave_ip}:${slave_port} pid=${LAG_PID} deadline=${deadline}"
}

# stop_lag_probe <label>
# 记 sweep_end、杀整个 lag 进程组（含 fork 的 lag_check，防下点 TRUNCATE 被残留
# busy-wait AccessShareLock 阻塞）、wait 收尾、lag_stats.sh 出该点 P50/P90/P95/P99+超时率。
stop_lag_probe() {
    local label=$1
    local lag_out="${result_dirs}/lag"
    local sweep_end_ms=$(date +%s%N | cut -c1-13)
    local win_line sweep_start_ms slave_ip slave_port
    win_line=$(cat "${lag_out}/.${label}.window" 2>/dev/null || echo "")
    sweep_start_ms=$(echo "$win_line" | awk '{print $1}')
    slave_ip=$(echo "$win_line" | awk '{print $2}')
    slave_port=$(echo "$win_line" | awk '{print $3}'); slave_port=${slave_port:-${PG_PORT}}

    # 杀进程组；set +e 防 wait 非零触发 set -e
    if [ -n "${LAG_PID:-}" ]; then
        local pgid=$(ps -o pgid= -p "${LAG_PID}" 2>/dev/null | tr -d ' ')
        set +e
        [ -n "${pgid}" ] && kill -- -"${pgid}" 2>/dev/null
        wait "${LAG_PID}" 2>/dev/null
        set -e
    fi

    local master_file="${lag_out}/master_insert_${label}.time"
    local delay_file="${lag_out}/${slave_ip}_${slave_port}_${label}_delay.result"

    if [ -f "$master_file" ] && [ -f "$delay_file" ]; then
        bash "${lag_tool_dir}/lag_stats.sh" "$master_file" "$delay_file" \
            "${lag_out}/lag_${label}.txt" "${sweep_start_ms}" "${sweep_end_ms}" \
            2>/dev/null || log "WARN" "[lag] sum2 失败 label=${label}"
        log "INFO" "[lag] 结果: ${lag_out}/lag_${label}.txt"
    else
        log "WARN" "[lag] 无样本 label=${label}（master=${master_file} delay=${delay_file}）"
    fi
    rm -f "${lag_out}/.${label}.window"
}

# lag 汇总（文字表+xlsx，随邮件发）：扫该场景各并发点 lag_*.txt，出 txt/csv/xlsx。
# 用法：lag_summary_for_scene <perf_mode 或 label_prefix>
lag_summary_for_scene() {
    local label_prefix=$1
    local lag_out="${result_dirs}/lag"
    [ -d "$lag_out" ] || { log "WARN" "[lag] 无 lag 目录，跳过汇总"; return 0; }

    local files label
    if [ -n "$label_prefix" ]; then
        files=$(ls "$lag_out"/lag_${label_prefix}_t*.txt 2>/dev/null)
        label="$label_prefix"
    else
        files=$(ls "$lag_out"/lag_*_t*.txt 2>/dev/null)
        label="all"
    fi
    [ -n "$files" ] || { log "WARN" "[lag] $lag_out 下无 lag_${label_prefix}_t*.txt（lag 未跑或无样本）"; return 0; }

    local sum_txt="$lag_out/lag_summary_${label}.txt"
    local sum_csv="$lag_out/lag_summary_${label}.csv"
    {
        echo "# lag 汇总  scene=${label}  生成=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 单位 ms；timeout_rate=被 statement_timeout 杀的 key 占比（lag>=wait_timeout）"
        echo "# P99/P95 含右删失：有超时 key 时这些百分位会触及截断上限（见各点 txt 的 NOTE）"
        printf "%-8s %6s %10s %10s %10s %10s %12s %10s\n" "threads" "n" "P50" "P90" "P95" "P99" "timeout_rate" "max_ms"
    } > "$sum_txt"
    echo "threads,n,P50,P90,P95,P99,timeout_rate,max_ms" > "$sum_csv"

    local f base threads
    for f in $files; do
        base=$(basename "$f")
        threads=$(echo "$base" | sed -n 's/.*_t\([0-9]\+\)\.txt$/\1/p')
        [ -z "$threads" ] && continue
        # 解析 lag_stats 产出的 txt：n=X avg=.. median=.. p90=.. p95=.. p99=.. max=..（P50 字段名是 median）；超时率在 # n= 行
        local n p50 p90 p95 p99 maxv timeout_rate
        read -r n p50 p90 p95 p99 maxv timeout_rate < <(
            awk '
              /^# n=/ { if (match($0, /timeout_rate=[0-9.]+%/)) { tr=substr($0,RSTART+13,RLENGTH-14) } }
              /^[[:space:]]*n=/ {
                for (i=1;i<=NF;i++){ split($i,kv,"="); v[kv[1]]=kv[2] }
                gsub(/ms$/,"",v["median"]); gsub(/ms$/,"",v["p90"]); gsub(/ms$/,"",v["p95"])
                gsub(/ms$/,"",v["p99"]); gsub(/ms$/,"",v["max"])
                print v["n"], v["median"], v["p90"], v["p95"], v["p99"], v["max"], tr
              }
            ' "$f"
        )
        timeout_rate=${timeout_rate:-0.00}
        printf "%-8s %6s %10s %10s %10s %10s %11s%% %10s\n" \
            "$threads" "${n:-0}" "${p50:--}" "${p90:--}" "${p95:--}" "${p99:--}" "$timeout_rate" "${maxv:--}" >> "$sum_txt"
        echo "${threads},${n:-0},${p50:-},${p90:-},${p95:-},${p99:-},${timeout_rate},${maxv:-}" >> "$sum_csv"
    done

    # 按并发点数值排序数据行（保留开头 # 注释行不动）
    local tmp_sorted=$(mktemp)
    grep '^#' "$sum_txt" > "$tmp_sorted"
    grep -v '^#' "$sum_txt" | sort -k1 -n >> "$tmp_sorted"
    mv "$tmp_sorted" "$sum_txt"

    # 出 xlsx（邮件 PERF 模式只收 png/xls，txt/csv 不收；xlsx 文件名含 'xls' 会被收）
    local sum_xlsx="$lag_out/lag_summary_${label}.xlsx"
    local py_tool="${lag_tool_dir}/../../3rdparty/python3.7.2/bin/python3"
    if [ -x "$py_tool" ]; then
        "$py_tool" - "$sum_csv" "$sum_xlsx" "复制延迟 lag 百分位 (${label})" <<'PY' 2>/dev/null || log "WARN" "[lag] xlsx 生成失败（不影响 txt/csv）"
import csv, sys
try:
    import openpyxl
    from openpyxl.styles import Font, Alignment, Border, Side, PatternFill
except ImportError:
    sys.exit("openpyxl 缺失")
csv_path, out_path, title = sys.argv[1], sys.argv[2], sys.argv[3]
wb = openpyxl.Workbook(); ws = wb.active; ws.title = "lag"
thin = Side(style="thin", color="999999"); border = Border(left=thin,right=thin,top=thin,bottom=thin)
hdr_font = Font(bold=True); hdr_fill = PatternFill("solid", fgColor="DDDDDD"); center = Alignment(horizontal="center")
ws.cell(row=1,column=1,value=title).font = Font(bold=True,size=13)
ws.merge_cells(start_row=1,start_column=1,end_row=1,end_column=8)
ws.cell(row=2,column=1,value="单位 ms；timeout_rate=被 statement_timeout 杀的 key 占比；P99/P95 含右删失").font = Font(italic=True,color="666666")
ws.merge_cells(start_row=2,start_column=1,end_row=2,end_column=8)
with open(csv_path, newline="") as f:
    r = 4
    for row in csv.reader(f):
        for c, val in enumerate(row, start=1):
            cell = ws.cell(row=r, column=c, value=val); cell.border = border; cell.alignment = center
            if r == 4: cell.font = hdr_font; cell.fill = hdr_fill
        r += 1
for col, w in zip("ABCDEFGH", [10,8,10,10,10,10,14,10]): ws.column_dimensions[col].width = w
wb.save(out_path)
PY
    fi

    log "INFO" "[lag] 汇总写入 ${sum_txt##*/} + ${sum_csv##*/} + ${sum_xlsx##*/}"
    grep -v '^#' "$sum_txt" | while read -r line; do log "INFO" "[lag] $line"; done || true
}
