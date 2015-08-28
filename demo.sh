#!/usr/bin/env bash

set -o history -o histexpand

max_nodes=${1:-2}
start_port=6650
#start_port=7856
end_port=$(($start_port+$max_nodes-1))
echo "##### Setting up nodes listening on ports from ${start_port} to ${end_port}"


function log_cmd() {
  echo -e "Running: \e[31;4m${1}\e[0m\n"
  #read
  echo -e "*** Complete:\n\e[1;92m${1}\e[0m\n"
}


function run() {
  echo -e "Running: \e[31;4m${1}\e[0m\n"
  pause
  #read
  eval "seq ${3:-$start_port} ${4:-$end_port} | xargs -n1 -P${2:-1} -I % ${1}"
  echo -e "*** Completed:\n\e[1;92m${1}\e[0m\n"
}

function run1(){
	echo $2 ===================
  echo -e "\e[1;74mOn NODE${2:-${start_port}}\e[0m\n"
  run "$1" 1 ${2:-${start_port}} ${2:-${start_port}}
}

function pause(){
   echo -e "\e[1;93m${*:-Press [Enter] key to continue...}\e[0m"
   read
}

#shopt -s extdebug
#trap read DEBUG
export PGUSER=postgres
export PGDATABASE=padb
###while false ; do #########################
run "pg_ctl stop -m immediate -D db%"
#pkill -9 postgres

run "rm -rf db%" 0
#rm -rf db*

run "initdb -D db% -A trust -U postgres" 0
ls
run "cp postgresql.conf pg_hba.conf db%" 0
run "pg_ctl -l bd%.log -D db% -o '-p%' -w start" 0
run "createdb -p %"
ps u
pause
run  "psql -p% -c\"CREATE EXTENSION btree_gist; CREATE EXTENSION bdr;\""

#while false ; do #########################
run1 "psql -p% -c\"SELECT bdr.bdr_group_create(local_node_name := 'node%', node_external_dsn := 'port=% dbname=padb user=postgres')\""
run1 "psql -p% -c\"SELECT bdr.bdr_node_join_wait_for_ready();\""

run "psql -p% -c\"BEGIN; SELECT bdr.bdr_group_join(\
	  local_node_name:='node%', \
	  node_external_dsn:='port=% dbname=padb user=postgres', \
	  join_using_dsn:='port='||(%-1)::text||' dbname=padb user=postgres'); COMMIT; \
	BEGIN; SELECT bdr.bdr_node_join_wait_for_ready(); COMMIT;\"" 1 $(($start_port+1))


run "psql -p% -c\"SELECT 'NODE'||current_setting('port') AS on_node_name, * FROM bdr.bdr_nodes;\""

run1 "psql -p% -f cr_padb.sql"
run "psql -p% -c\"SELECT 'NODE'||current_setting('port') AS on_node_name, table_name FROM information_schema.tables WHERE table_schema='pa'\""
###done
run1 "psql -p% -c\"DELETE FROM pa.nodes; INSERT INTO pa.nodes (host_name, ip_addr) SELECT 'EP'||v::text, ('10.1.1.'||v::text)::inet FROM generate_series(1, 10) AS gs(v);\"" $end_port
run "psql -p% -c\"SELECT * FROM pa.nodes\"" 1 $start_port $(($end_port-1))

run1 "psql -p% -c\"INSERT INTO pa.nodes (host_name, ip_addr) SELECT 'EP'||v::text, ('10.1.1.'||v::text)::inet FROM generate_series(142, 149) AS gs(v);\""
run "psql -p% -c\"SELECT * FROM pa.nodes\"" 1 $start_port $(($end_port-1))

run1 "pg_ctl stop -m immediate -D db%"

run1 "psql -p% -c\"INSERT INTO pa.stores(id, node_id, erfstore_id, probe_name, erfstore_name, vision) \
  SELECT uuid_generate_v4() AS id, n.id, ((1000*nn)+seq.s)::text, n.host_name, 'ROTFILE-'||((1000*nn)+seq.s)::text, true \
  FROM (SELECT row_number() OVER () AS nn, * FROM pa.nodes) AS n, generate_series(1,3) AS seq(s);\"" $end_port
run1 "psql -p% -c\"SELECT count(*) FROM pa.stores\"" $end_port
run1 "psql -p% -c\"SELECT * FROM pa.stores LIMIT 10\"" $end_port

run1 "pg_ctl -l bd%.log -D db% -o '-p%' -w start"
pause

run1 "psql -p% -c\"SELECT count(*) FROM pa.stores\""
run1 "psql -p% -c\"SELECT * FROM pa.stores LIMIT 10\""

pause "Memory consumption..."
top -p $(pgrep -fd", " "/home/rad.cirskis/pg94/bin/postgres")

#done
