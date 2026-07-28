#!/usr/bin/env python3
"""lag_stats.py —— 对 lag.csv 算百分位（纯标准库，零 DB 依赖，可独立复用）。

输入 csv 需有 lag_ms 列（lag_probe.py 产出的就是这个格式；别的来源只要列名对上也行）。
负值过滤（时钟偏差偶发）。

百分位用 nearest-rank（排序后取第 ceil(q*n/100) 个真实样本，不插值）——
返回的一定是某次真实观测值，不"造"介于两样本之间的数。对延迟这种离散实测数据，
"第 X% 位置的样本"语义最干净；样本量大时和插值结论无差。

用法：
  python3 lag_stats.py out/lag.csv                          # 默认 P50/P90/P99
  python3 lag_stats.py out/lag.csv --percentiles 50,90,95,99
  python3 lag_stats.py out/lag.csv --out stats.txt          # 同时写文件
"""
import argparse
import csv
import math
import sys


def pct(vals, q):
    """第 q 百分位（nearest-rank）：排序后取第 ceil(q*n/100) 个真实样本，不插值。
    返回的一定是某个真实样本值（不造数）。"""
    if not vals:
        return None
    s = sorted(vals)
    rank = math.ceil(q / 100.0 * len(s))
    rank = min(max(rank, 1), len(s))   # 钳到 [1, n]，防 q=0 或 q>100 越界
    return round(s[rank - 1], 3)


def read_lag_csv(path):
    """读 lag_ms 列，过滤负值（时钟偏差偶发）。"""
    vals = []
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                v = float(r["lag_ms"])
            except (ValueError, KeyError):
                continue
            if v >= 0:
                vals.append(v)
    return vals


def main():
    ap = argparse.ArgumentParser(description="对 lag.csv 算百分位")
    ap.add_argument("path", help="lag.csv 路径")
    ap.add_argument("--percentiles", default="50,90,99",
                    help="百分位列表，默认 50,90,99（例 50,90,95,99）")
    ap.add_argument("--out", help="写到文件（可选）")
    a = ap.parse_args()
    percentiles = [int(x) for x in a.percentiles.split(",") if x.strip()]

    vals = read_lag_csv(a.path)
    if not vals:
        sys.exit(f"{a.path}: 无有效 lag 样本")

    lines = [f"# lag stats  source={a.path}",
             f"# n={len(vals)}  min={min(vals):.3f}  max={max(vals):.3f} ms"]
    for q in percentiles:
        lines.append(f"P{q:>3} = {pct(vals, q)} ms")
    out = "\n".join(lines)
    print(out)
    if a.out:
        with open(a.out, "w") as f:
            f.write(out + "\n")
        print(f"\n写入 {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
