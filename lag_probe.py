#!/usr/bin/env python3
"""lag_probe.py —— 复制延迟探针（只采集，不算百分位；统计见 lag_stats.py）。

writer 每 --write-ms(100ms) 用服务端 clock_timestamp() 往 marker 表写一条；
reader 每 --read-ms(20ms) 新事务读最新 marker，用服务端时钟算 lag_ms。
产出 <outdir>/lag.csv（ts, marker_id, lag_ms）。

依赖：psycopg2。
凭据走环境变量：PGPASSWORD / PGPORT / PGDB / PGUSER / PGSSLMODE / CA_BUNDLE
                 LAG_TABLE（marker 表名，默认 replica_lag_marker，冲突可改）

测准 lag 的关键设计（不可改）：
  - 服务端 clock_timestamp() 打戳 + 服务端算 clock_timestamp()-ts（lag 是成品数字，
    不受客户端/写 csv 延迟影响）
  - reader 每轮新连接 + autocommit 取新快照（否则长事务冻结旧快照，测到的是快照延迟）
  - 读"最新"marker（ORDER BY id DESC LIMIT 1）不按顺序追（防 reader_poll 周期被挤时
    读到旧 marker，把 lag 测成轮询积压伪影）
  - 仅当 id > last_read_id 才记一条样本（不重复记同一行）

用法：
  export PGPASSWORD='xxx' PGSSLMODE=require CA_BUNDLE=/tmp/global-bundle.pem
  python3 lag_probe.py --writer-host <主> --reader-host <备> --time 300 --outdir ./out
  # 跑完用 lag_stats.py ./out/lag.csv 算百分位
"""
import argparse
import csv
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone

# ── 连接配置（环境变量）──────────────────────────────────────────
PORT     = os.environ.get("PGPORT", "5432")
DBNAME   = os.environ.get("PGDB", "postgres")
USER     = os.environ.get("PGUSER", "postgres")
PASSWORD = os.environ.get("PGPASSWORD", "")
SSLMODE  = os.environ.get("PGSSLMODE", "")        # 空=不强制 SSL；Aurora 用 require/verify-full
CA       = os.environ.get("CA_BUNDLE", "/tmp/global-bundle.pem")
TABLE    = os.environ.get("LAG_TABLE", "replica_lag_marker")


def _ident(name):
    """表名只允许合法标识符，防注入（表名走 f-string 拼接，需校验）。"""
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name):
        sys.exit(f"非法表名（LAG_TABLE）: {name!r}，只允许字母/数字/下划线且不以数字开头")
    return name


def dsn(host, rw=False):
    parts = [f"host={host}", f"port={PORT}", f"dbname={DBNAME}", f"user={USER}",
             f"password={PASSWORD}", "connect_timeout=5"]
    if SSLMODE:
        parts += [f"sslmode={SSLMODE}", f"sslrootcert={CA}"]
    if rw:  # writer 连 read-write，保证连到主（failover 后 DNS 没翻时兜底）
        parts.append("target_session_attrs=read-write")
    return " ".join(parts)


def connect(host, rw=False):
    try:
        import psycopg2
    except ImportError:
        sys.exit("lag_probe.py 需要 psycopg2：pip install psycopg2-binary")
    c = psycopg2.connect(dsn(host, rw))
    c.autocommit = True   # 关键：每条语句独立事务，强制取新快照
    return c


def ensure_tables(writer_host):
    t = _ident(TABLE)
    c = connect(writer_host, rw=True)
    try:
        with c.cursor() as cur:
            cur.execute(f"""CREATE TABLE IF NOT EXISTS {t}(
                id bigserial PRIMARY KEY, ts timestamptz NOT NULL, scene text NOT NULL)""")
            cur.execute(f"TRUNCATE TABLE {t} RESTART IDENTITY")  # 每次从空开始
    finally:
        c.close()


# ── 采集 ──────────────────────────────────────────────────────────
class Probe:
    def __init__(self, a):
        self.a = a
        self.stop = threading.Event()
        self.last_read_id = 0          # reader 已读到的最大 marker id（≈ lag 样本数，做进度）
        os.makedirs(a.outdir, exist_ok=True)
        self.fr = open(f"{a.outdir}/lag.csv", "w", newline="")
        self.wr = csv.writer(self.fr)
        self.wr.writerow(["ts", "marker_id", "lag_ms"])

    @staticmethod
    def _now():
        return datetime.now(timezone.utc).isoformat()

    def writer_probe(self):
        t = _ident(TABLE)
        ins = f"INSERT INTO {t}(ts,scene) VALUES(clock_timestamp(),%s)"
        while not self.stop.is_set():
            t0 = time.time()
            c = None
            try:
                c = connect(self.a.writer_host, rw=True)
                with c.cursor() as cur:
                    cur.execute(ins, (self.a.scene,))
            except Exception:
                pass  # 单独量 lag，写失败跳过这条（failover 期会连不上，正常）
            finally:
                if c:
                    try: c.close()
                    except Exception: pass
            self.stop.wait(max(0.0, self.a.write_ms / 1000.0 - (time.time() - t0)))

    def reader_poll(self):
        t = _ident(TABLE)
        # 读"最新"marker（ORDER BY id DESC LIMIT 1），不按顺序追——
        # 防 reader_poll 周期被挤时读到旧 marker，把 lag 测成积压伪影。
        # lag 由服务端算（reader 的 clock_timestamp - writer 写入时的 ts）。
        q = (f"SELECT id, EXTRACT(EPOCH FROM (clock_timestamp()-ts))*1000 AS lag_ms "
             f"FROM {t} ORDER BY id DESC LIMIT 1")
        while not self.stop.is_set():
            t0 = time.time()
            c = None
            try:
                c = connect(self.a.reader_host)   # 每轮新连接 = 新快照
                with c.cursor() as cur:
                    cur.execute(q)
                    row = cur.fetchone()
                if row and row[0] > self.last_read_id:   # 只在新 marker 出现时记
                    mid, lag_ms = row
                    self.last_read_id = mid
                    self.wr.writerow([self._now(), mid, round(float(lag_ms), 3)])
            except Exception:
                pass  # reader 偶发连不上（failover 期），跳过
            finally:
                if c:
                    try: c.close()
                    except Exception: pass
            self.fr.flush()
            self.stop.wait(max(0.0, self.a.read_ms / 1000.0 - (time.time() - t0)))

    def run(self):
        ensure_tables(self.a.writer_host)
        tw = threading.Thread(target=self.writer_probe, name="writer_probe", daemon=True)
        tr = threading.Thread(target=self.reader_poll,  name="reader_poll",  daemon=True)
        tw.start(); tr.start()
        deadline = time.time() + self.a.time
        while time.time() < deadline:
            self.stop.wait(min(10, max(0.0, deadline - time.time())))
            if not self.stop.is_set():
                print(f"  进度: 约 {self.last_read_id} 条 lag 样本", file=sys.stderr)
        self.stop.set()
        tw.join(timeout=3); tr.join(timeout=3)
        self.fr.close()


def main():
    ap = argparse.ArgumentParser(description="复制延迟探针（采集 lag.csv）")
    ap.add_argument("--writer-host", required=True, help="主地址（域名/VIP/IP）")
    ap.add_argument("--reader-host", required=True, help="备地址（域名/VIP/IP）")
    ap.add_argument("--scene", default="default", help="场景标签")
    ap.add_argument("--time", type=int, required=True, help="采集秒数")
    ap.add_argument("--write-ms", type=int, default=100, help="写探针间隔 ms（默认 100）")
    ap.add_argument("--read-ms",  type=int, default=20,  help="读轮询间隔 ms（默认 20）")
    ap.add_argument("--outdir", required=True, help="输出目录（产 lag.csv）")
    a = ap.parse_args()
    p = Probe(a)
    p.run()
    print(f"\n采集完成: {a.outdir}/lag.csv（约 {p.last_read_id} 条样本）", file=sys.stderr)
    print(f"算百分位: python3 lag_stats.py {a.outdir}/lag.csv", file=sys.stderr)


if __name__ == "__main__":
    main()
