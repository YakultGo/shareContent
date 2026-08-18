# ==============================================================================
# 脚本名称: scheduled_rds_test.tcl
# 说明: 读取环境变量并运行 TPROC-H 压测
# ==============================================================================

dbset db pg
dbset bm TPROC-H

# 从 Shell 环境变量中读取 IP 和并发数
set server_ip $::env(server_ip)
set vuser_count $::env(vuser_count)

puts "server_ip: $server_ip"
puts "vuser_count: $vuser_count"

# 配置连接参数
diset connection pg_host "$server_ip"
diset connection pg_port "5432"

diset tpch pg_tpch_user "root"
diset tpch pg_tpch_pass "Huawei@234"
diset tpch pg_tpch_dbase "tpchtest"

diset tpch pg_degree_of_parallel 1
diset tpch pg_total_querysets 999999

loadscript

# 设置当前阶梯并发数
vuset vu "$vuser_count"
vuset showoutput 0

vucreate
vurun
