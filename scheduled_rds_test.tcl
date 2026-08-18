dbset db pg
dbset bm TPC-H

# 从 Shell 环境变量获取当前阶梯的参数
set server_ip $::env(server_ip)
set vuser_count $::env(vuser_count)

diset connection pg_host "$server_ip"
diset connection pg_port "5432"

diset tpch pg_tpch_user "root"
diset tpch pg_tpch_pass "Huawei@234"
diset tpch pg_tpch_dbase "tpchtest"

diset tpch pg_degree_of_parallel 1
diset tpch pg_total_querysets 999999

loadscript

vuset vu "$vuser_count"
vuset showoutput 0

vucreate
vurun
