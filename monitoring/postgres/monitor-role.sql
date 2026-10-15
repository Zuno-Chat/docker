-- Run by postgres-monitor-init (docker-compose.yml) on every `up`, as synapse,
-- with psql -v pw=<POSTGRES_MONITOR_PASSWORD>. Safe to repeat: it creates the
-- role once and sets its password every time, so a new value in .env applies
-- on the next `up`.
SELECT 'CREATE ROLE zuno_monitor' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'zuno_monitor')\gexec
ALTER ROLE zuno_monitor WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 3;
GRANT pg_monitor TO zuno_monitor;

-- Counts for the New account and New report notifications
-- (monitoring/postgres/queries.yaml). zuno_monitor reads no Synapse table: it
-- may only call these, which run as synapse and return bare row counts.
-- Bodies are checked when called, not here: on a first deploy Synapse has not
-- created its tables yet. scripts/backup.sh leaves this schema out of its dumps.
CREATE SCHEMA IF NOT EXISTS monitoring;
SET check_function_bodies = off;

-- Every account ever registered, deactivated ones included (Synapse keeps
-- their rows); appservice users and guests left out.
CREATE OR REPLACE FUNCTION monitoring.accounts() RETURNS bigint
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
  AS $$ SELECT count(*) FROM users WHERE appservice_id IS NULL AND is_guest = 0 $$;

-- Every report ever filed, by what was reported.
CREATE OR REPLACE FUNCTION monitoring.reports() RETURNS TABLE (kind text, filed bigint)
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
  AS $$
    SELECT 'message', count(*) FROM event_reports
    UNION ALL SELECT 'room', count(*) FROM room_reports
    UNION ALL SELECT 'user', count(*) FROM user_reports
  $$;

REVOKE ALL ON FUNCTION monitoring.accounts(), monitoring.reports() FROM PUBLIC;
GRANT USAGE ON SCHEMA monitoring TO zuno_monitor;
GRANT EXECUTE ON FUNCTION monitoring.accounts(), monitoring.reports() TO zuno_monitor;
