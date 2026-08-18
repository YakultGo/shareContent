# ==============================================================================
# 脚本名称: scheduled_rds_test.tcl
# 说明: HammerDB 读取环境变量执行 PostgreSQL/Aurora 压测
# ==============================================================================

dbset db pg
dbset bm TPC-H

# 从环境变量中动态读取当前测试的配置
set server_ip $::env(server_ip)
set vuser_count $::env(vuser_count)

# 配置 Aurora / PostgreSQL 连接信息
diset connection pg_host "$server_ip"
diset connection pg_port "5432"

diset tpch pg_tpch_user "root"
diset tpch pg_tpch_pass "Huawei@234"
diset tpch pg_tpch_dbase "tpchtest"

diset tpch pg_degree_of_parallel 1
diset tpch pg_total_querysets 999999

loadscript

# 设置当前阶梯的并发数
vuset vu "$vuser_count"
vuset showoutput 0

vucreate
vurun
