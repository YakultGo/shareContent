#!/bin/bash
# lag_stats.sh —— 对单并发点的 lag 算百分位（融 perf 版）。
#
# 输入：master_insert_${label}.time + ${slave}_${port}_${label}_delay.result
# （都由 lag_probe.sh / lag_check.sh 产出，落 out_dir）。
# join on key，delay = t_replica - t_master（ms 级 epoch）。
#
# 与原 /root/replica_lag/lag_stats.sh 差异（融 perf 用）：
#   - 改为指定 label 单点统计（原版 glob *_delay.result 全量 + ALL 合并）。
#   - 窗口过滤：t_master 落在 [sweep_start, sweep_end] 外的 key 丢弃，排除 lag
#     探针在 sysbench run 前后的无负载样本（deadline 截止循环仍可能有边界样本）。
#   - 超时右删失：TIMEOUT 行（lag>=wait_timeout）按 320000ms 截断值计入分布参与
#     nearest-rank 排序，不丢弃（否则低估 P99）；同时单列超时率。
#   - pidx nearest-rank 算法一字不动。
#
# 用法：
#   lag_stats.sh <master_file> <delay_file> <out_txt> [sweep_start_ms sweep_end_ms]
#   # sweep 窗口可选；不给则不过滤。
set -uo pipefail

if [ $# -lt 3 ]; then
  echo "Usage: $0 <master_file> <delay_file> <out_txt> [sweep_start_ms sweep_end_ms]"
  exit 1
fi

MASTER_FILE=$1
DELAY_FILE=$2
OUT_TXT=$3
SWEEP_START=${4:-}
SWEEP_END=${5:-}

if [ ! -f "$MASTER_FILE" ]; then
  echo "Cannot find $MASTER_FILE" >&2; exit 1
fi
if [ ! -f "$DELAY_FILE" ]; then
  echo "Cannot find $DELAY_FILE" >&2; exit 1
fi

# 右删失截断值：与 lag_check.sh 默认 WAIT_TIMEOUT_MS 对齐
TIMEOUT_CEIL=320000

DIFFS=$(mktemp)
awk -v master="$MASTER_FILE" -v diffs="$DIFFS" \
    -v wstart="$SWEEP_START" -v wend="$SWEEP_END" -v tceil="$TIMEOUT_CEIL" '
  BEGIN {
    while ((getline line < master) > 0) {
      split(line, a, " ")
      mk[a[1]] = a[2]      # key -> t_master (ms epoch)
    }
  }
  {
    key = $1; rt = $2
    if (!(key in mk)) next
    mt = mk[key]
    # 窗口过滤：t_master 在 sweep 窗口外则丢弃（排除无负载样本）
    if (wstart != "" && mt+0 < wstart+0) next
    if (wend != "" && mt+0 > wend+0) next
    if (rt == "TIMEOUT") {
      # 右删失：lag>=wait_timeout 的 key 按截断值计入分布，不丢
      diff = tceil+0
      timeout_n++
    } else if (rt ~ /^[0-9]+$/) {
      diff = (rt - mt)
      if (diff < 0) diff = 0
    } else {
      next    # 其它非数字行（不应出现）跳过
    }
    print diff >> diffs
    total_n++
  }
  END {
    print "timeout=" timeout_n+0
    print "total=" total_n+0
  }
' "$DELAY_FILE" > /tmp/_lag_meta_$$ 2>/dev/null

timeout_n=$(grep '^timeout=' /tmp/_lag_meta_$$ | cut -d= -f2)
total_n=$(grep '^total=' /tmp/_lag_meta_$$ | cut -d= -f2)
rm -f /tmp/_lag_meta_$$
timeout_n=${timeout_n:-0}
total_n=${total_n:-0}

{
  echo "# lag stats  label=$(basename "$DELAY_FILE" | sed 's/_delay.result$//')"
  echo "# source=$DELAY_FILE master=$MASTER_FILE"
  echo "# n=$total_n  timeout=$timeout_n  timeout_rate=$(awk "BEGIN{if($total_n>0) printf \"%.2f%%\", $timeout_n*100/$total_n; else print \"0%\"}")"
  echo "# window=[${SWEEP_START:-none},${SWEEP_END:-none}] ms  timeout_ceil=${TIMEOUT_CEIL}ms"
  sort -n "$DIFFS" | awk -v tceil="$TIMEOUT_CEIL" '
    function pidx(n, p,   i) {
      i = int((p / 100.0) * n)
      if ((p / 100.0) * n > i) i++
      if (i < 1) i = 1
      if (i > n) i = n
      return i
    }
    { v[++n] = $1 + 0; sum += $1 }
    END {
      if (n == 0) { print "  no samples"; exit }
      min = v[1]; max = v[n]
      mean = sum / n
      avg = (n > 2) ? (sum - min - max) / (n - 2) : mean
      printf "  n=%d  avg=%.2fms  mean=%.2fms  median=%.2fms  p90=%.2fms  p95=%.2fms  p99=%.2fms  min=%.2fms  max=%.2fms\n", \
             n, avg, mean, v[pidx(n,50)], v[pidx(n,90)], v[pidx(n,95)], v[pidx(n,99)], min, max
      if (max+0 >= tceil+0) print "  NOTE: max 触及右删失上限 " tceil "ms（存在超时 key，P99/p99 含截断值）"
    }
  '
} > "$OUT_TXT"

cat "$OUT_TXT"
rm -f "$DIFFS"
