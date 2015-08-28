-- listen ch1;
/*
CREATE DATABASE padb TABLESPACE probedb;
*/
CREATE EXTENSION plpythonu;

CREATE SCHEMA IF NOT EXISTS pa;

CREATE OR REPLACE FUNCTION uuid_generate_v4()
RETURNS uuid LANGUAGE plpythonu AS $$
  from uuid import uuid4
  return uuid4()$$;

-- select * from pg_stat_activity 
CREATE OR REPLACE FUNCTION pa.handle_table_change() RETURNS trigger AS $$
import time
import json

event = TD["event"]
old = TD["old"]
new = TD["new"]
row = old if event=="DELETE" else new

# Increment the version number if the update was local
if event == "UPDATE" and "version" in row and old["version"] == new["version"]:
  row["version"] += 1 

#TD["table_name"]  ## contains the name of the table on which the trigger occurred.
#TD["table_schema"]  ## contains the schema of the table on which the trigger occurred.
#TD["relid"] ##contains the OID of the table on which the trigger occurred.
#TD["args"]  ## If the CREATE TRIGGER command included arguments, they are available in TD["args"][0] to TD["args"][n-1].

stmt1 = plpy.prepare("SELECT pg_notify('pa.changes', $1)", ["text"])
stmt2 = plpy.prepare("SELECT pg_notify('pa.changes.web', $1)", ["text"])

remote = False
if "remote" in row:
  remote = row["remote"]

message = json.dumps({
  "event": event,
  "table": TD["table_name"],
  "schema": TD["table_schema"],
  "entry": row})

if not remote or event == "DELETE":
  # do not place on the queue if it is a romote update
  rv = plpy.execute(stmt1, [message])

rv = plpy.execute(stmt2, [message])

#plpy.info(TD)
#with open("/endace/pgsql/update.log", "a") as f:
  #print >>f, "#####:", time.time()
  #print >>f, TD
 
$$ LANGUAGE plpythonu;


-- SELECT uuid_generate_v4()
-- DROP TABLE IF EXISTS pa.nodes CASCADE;
CREATE TABLE pa.nodes (
  id uuid DEFAULT uuid_generate_v4() NOT NULL PRIMARY KEY,
  ip_addr inet,
  host_name text,
  is_pa boolean DEFAULT false,
  -- record update propageted from a remote PA the most recent update
  remote bool DEFAULT false,
  version int DEFAULT 0
);
ALTER TABLE pa.nodes  OWNER TO admin;
GRANT ALL ON TABLE pa.nodes TO admin;
GRANT SELECT ON TABLE pa.nodes TO public;
GRANT SELECT ON TABLE pa.nodes TO postgres_ro;
GRANT SELECT ON TABLE pa.nodes TO postgres_ui;


-- DROP TRIGGER IF EXISTS edit_nodes_tr ON pa.nodes;
CREATE TRIGGER edit_nodes_tr
  AFTER INSERT OR UPDATE
  ON pa.nodes
  FOR EACH ROW
  -- WHEN ( NOT NEW.remote )
  EXECUTE PROCEDURE pa.handle_table_change();

-- DROP TRIGGER IF EXISTS delete_nodes_tr ON pa.nodes;
CREATE TRIGGER delete_nodes_tr
  AFTER DELETE
  ON pa.nodes
  FOR EACH ROW
  -- WHEN ( NOT OLD.remote )
  EXECUTE PROCEDURE pa.handle_table_change();

-- DROP TABLE IF EXISTS pa.stores CASCADE;
CREATE TABLE pa.stores
(
  id uuid NOT NULL DEFAULT uuid_generate_v4() PRIMARY KEY,
  node_id uuid NOT NULL REFERENCES pa.nodes ON DELETE CASCADE,
  erfstore_id character varying NOT NULL,
  probe_name character varying NOT NULL,
  erfstore_name character varying NOT NULL,
  tablespace character varying,
  cluster_partition smallint,
  vision boolean NOT NULL,
  last_ts bigint NOT NULL DEFAULT 0,
  next_flow_id bigint NOT NULL DEFAULT 0,
  archive boolean NOT NULL DEFAULT false,
  created_by character varying,
  temporary boolean NOT NULL DEFAULT false,
  -- record update propageted from a remote PA 
  remote boolean DEFAULT false,
  version int DEFAULT 0
);
ALTER TABLE pa.stores  OWNER TO admin;
GRANT ALL ON TABLE pa.stores TO admin;
GRANT SELECT ON TABLE pa.stores TO public;
GRANT SELECT ON TABLE pa.stores TO postgres_ro;
GRANT SELECT ON TABLE pa.stores TO postgres_ui;

-- DROP TRIGGER IF EXISTS edit_stores_tr ON pa.stores;
CREATE TRIGGER edit_stores_tr
  AFTER INSERT OR UPDATE
  ON pa.stores
  FOR EACH ROW
  -- WHEN ( NOT NEW.remote )
  EXECUTE PROCEDURE pa.handle_table_change();

-- DROP TRIGGER IF EXISTS delete_stores_tr ON pa.stores;
CREATE TRIGGER delete_stores_tr
  AFTER DELETE
  ON pa.stores
  FOR EACH ROW
  -- WHEN ( NOT OLD.remote )
  EXECUTE PROCEDURE pa.handle_table_change();


DROP TRIGGER IF EXISTS edit_erfstores_tr ON erfstores;
CREATE TRIGGER edit_erfstores_tr
  AFTER INSERT OR UPDATE
  ON erfstores
  FOR EACH ROW
  EXECUTE PROCEDURE pa.handle_table_change();

DROP TRIGGER IF EXISTS delete_erfstores_tr ON erfstores;
CREATE TRIGGER delete_erfstores_tr
  AFTER DELETE
  ON erfstores
  FOR EACH ROW
  EXECUTE PROCEDURE pa.handle_table_change();

-- 
-- SELECT pa.push_to_pa();
CREATE OR REPLACE FUNCTION pa.push_to_pa(pa inet DEFAULT NULL) 
RETURNS void
LANGUAGE plpythonu 
AS $$
import json
import socket
import os
import uuid 
import hashlib

stmt1 = plpy.prepare("SELECT pg_notify('pa.changes', $1)", ["text"])
stmt2 = plpy.prepare("SELECT pg_notify('pa.changes.web', $1)", ["text"])

def send(message, remote=False):

  if type(message) != str:
    message = json.dumps(message)

  plpy.notice("### Seding message:\n" + message)

  if not remote:
    # do not place on the queue if it is a romote update
    rv = plpy.execute(stmt1, [message])

  rv = plpy.execute(stmt2, [message])

rv = plpy.execute("SELECT * FROM pa.get_node_attr()") 

node_id = str(rv[0]["id"])
ip_addr = str(rv[0]["ip_addr"])
host_name = str(rv[0]["host_name"])

message = {
  "event": "INSERT",
  "table": "nodes",
  "schema": "pa",
  "entry": dict(id=node_id, ip_addr=ip_addr, host_name=host_name)
}

plpy.notice("#####")
send(message)

for row in  plpy.cursor("SELECT * FROM erfstores"):
  row["node_id"] = node_id
  message = {
    "event": "INSERT",
    "table": "stores",
    "schema": "pa",
    "entry": row}
  send(message)
$$;

-- SELECT * FROM pa.get_node_attr();
CREATE OR REPLACE FUNCTION pa.get_node_attr() 
RETURNS TABLE(id text, host_name text, ip_addr text)
LANGUAGE plpythonu 
AS $$
import json
import socket
import os
import uuid 
import hashlib

def get_serial_no():
  return os.popen(
  """
  /opt/tms/bin/cli -t "show version" | fgrep "Serial number:" | tr -d ' '| cut -d: -f2
  """).read().strip()

def get_host_name():
  return os.popen("hostname").read().strip()

def get_id():
  serial_no = get_serial_no()
  return uuid.UUID(hashlib.md5(serial_no).hexdigest())

def get_ip_addr():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80))
    ip_addr = s.getsockname()[0] 
    s.close()
    return ip_addr

if "node_attr" not in SD:
  SD["node_attr"] = (get_id(), get_host_name(), get_ip_addr())

yield SD["node_attr"]
$$;
