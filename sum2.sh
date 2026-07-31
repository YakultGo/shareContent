#!/bin/bash
# Display replica delay results.
#
# Reads master_insert_time.result and every *_delay.result file produced by
# check_replica.sh, joins them on the key, and prints summary statistics
# (avg/mean/p95/p99/min/max) per replica and combined.
#
# By default only the summary is printed. Use --detail to also print per-row
# data (not recommended for KEY_COUNT > 100 -- floods the terminal).
#
# delay = replica_ts - master_ts   (timestamps are ms since epoch)

DETAIL=0
for arg in "$@"; do
  if [ "$arg" = "--detail" ]; then
    DETAIL=1
  fi
done

MASTER_FILE=master_insert_time.result
if [ ! -f "$MASTER_FILE" ]; then
  echo "Cannot find $MASTER_FILE"
  exit 1
fi

AGG=$(mktemp)
FOUND=0

for rf in *_delay.result; do
  [ -f "$rf" ] || continue
  FOUND=1
  name="${rf%_delay.result}"
  echo "----- $name -----"
  diffs=$(mktemp)
  if [ "$DETAIL" -eq 1 ]; then
    awk -v master="$MASTER_FILE" -v agg="$AGG" -v diffs="$diffs" '
      BEGIN {
        while ((getline line < master) > 0) {
          split(line, a, " ")
          mk[a[1]] = a[2]
        }
      }
      {
        key = $1; rt = $2
        if (rt !~ /^[0-9]+$/) next        # skip error lines from check_replica.sh
        if (!(key in mk)) next
        diff = (rt - mk[key])
        if (diff < 0) diff = 0
        print key, mk[key], rt, diff      # per-row detail to stdout
        print diff >> diffs
        print diff >> agg
      }
    ' "$rf"
  else
    awk -v master="$MASTER_FILE" -v agg="$AGG" -v diffs="$diffs" '
      BEGIN {
        while ((getline line < master) > 0) {
          split(line, a, " ")
          mk[a[1]] = a[2]
        }
      }
      {
        key = $1; rt = $2
        if (rt !~ /^[0-9]+$/) next
        if (!(key in mk)) next
        diff = (rt - mk[key])
        if (diff < 0) diff = 0
        print diff >> diffs
        print diff >> agg
      }
    ' "$rf"
  fi
  sort -n "$diffs" | awk '
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
    }
  '
  rm -f "$diffs"
done

if [ "$FOUND" -eq 0 ]; then
  echo "No *_delay.result files found."
  rm -f "$AGG"
  exit 0
fi

echo "----- ALL (combined) -----"
sort -n "$AGG" | awk '
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
  }
'

rm -f "$AGG"
