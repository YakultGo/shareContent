# ==============================================================================
# 脚本名称: tpch_build.tcl
# 说明: HammerDB 构建 10GB TPROC-H 数据库表结构与导入数据 (32 线程并行)
# ==============================================================================

dbset db pg
dbset bm TPROC-H

# 数据库连接参数
diset connection pg_host "192.168.200.242"  ;# 集群 endpoint(VIP，指向主)
diset connection pg_port "5432"

diset tpch pg_tpch_superuser "root"
diset tpch pg_tpch_superuserpass "Taurus_123"
diset tpch pg_tpch_defaultdbase "tpchtest"

diset tpch pg_tpch_user "root"
diset tpch pg_tpch_pass "Taurus_123"
diset tpch pg_tpch_dbase "tpchtest"

# 设置数据规模为 10GB，并使用 32 线程并发导入数据
diset tpch pg_scale_fact 10
diset tpch pg_num_tpch_threads 32

print dict

# 执行架构构建与数据加载
buildschema
