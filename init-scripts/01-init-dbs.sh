#!/bin/bash
# ==============================================================================
# 01-init-dbs.sh - PostgreSQL Multi-Database and Role Initialization Script
# Executed automatically by postgres:16-alpine on container first startup.
# ==============================================================================

set -eo pipefail

echo ">>> [INIT-DBS] Starting automated initialization of databases and roles..."

# Default fallbacks if not explicitly provided in environment
AIRFLOW_DB="${AIRFLOW_DB:-airflow_backend}"
AIRFLOW_DB_USER="${AIRFLOW_DB_USER:-airflow}"
AIRFLOW_DB_PASSWORD="${AIRFLOW_DB_PASSWORD:-airflow}"

SUPERSET_DB="${SUPERSET_DB:-superset}"
SUPERSET_DB_USER="${SUPERSET_DB_USER:-superset}"
SUPERSET_DB_PASSWORD="${SUPERSET_DB_PASSWORD:-superset}"

ANALYTICS_STAGING_DB="${ANALYTICS_STAGING_DB:-analytics_staging}"
ANALYTICS_PROD_DB="${ANALYTICS_PROD_DB:-analytics_prod}"
DBT_DB_USER="${DBT_DB_USER:-dbt_runner}"
DBT_DB_PASSWORD="${DBT_DB_PASSWORD:-dbt_runner_pass}"

# Helper function to create user if it doesn't already exist
create_user() {
    local username="$1"
    local password="$2"
    echo ">>> [INIT-DBS] Ensuring user '${username}' exists..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${username}') THEN
                CREATE USER ${username} WITH PASSWORD '${password}';
            ELSE
                ALTER USER ${username} WITH PASSWORD '${password}';
            END IF;
        END
        \$\$;
EOSQL
}

# Helper function to create database if it doesn't already exist
create_database() {
    local database="$1"
    local owner="$2"
    echo ">>> [INIT-DBS] Ensuring database '${database}' exists (owner: ${owner})..."
    local exists
    exists=$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc "SELECT 1 FROM pg_database WHERE datname='${database}';")
    if [ "$exists" != "1" ]; then
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
            CREATE DATABASE ${database} OWNER ${owner};
EOSQL
    else
        echo ">>> [INIT-DBS] Database '${database}' already exists. Updating owner..."
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
            ALTER DATABASE ${database} OWNER TO ${owner};
EOSQL
    fi
}

# ------------------------------------------------------------------------------
# 1. Airflow Backend Database
# ------------------------------------------------------------------------------
create_user "${AIRFLOW_DB_USER}" "${AIRFLOW_DB_PASSWORD}"
create_database "${AIRFLOW_DB}" "${AIRFLOW_DB_USER}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${AIRFLOW_DB}" <<-EOSQL
    GRANT ALL PRIVILEGES ON DATABASE ${AIRFLOW_DB} TO ${AIRFLOW_DB_USER};
    GRANT ALL ON SCHEMA public TO ${AIRFLOW_DB_USER};
EOSQL

# ------------------------------------------------------------------------------
# 2. Superset Metadata Database
# ------------------------------------------------------------------------------
create_user "${SUPERSET_DB_USER}" "${SUPERSET_DB_PASSWORD}"
create_database "${SUPERSET_DB}" "${SUPERSET_DB_USER}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${SUPERSET_DB}" <<-EOSQL
    GRANT ALL PRIVILEGES ON DATABASE ${SUPERSET_DB} TO ${SUPERSET_DB_USER};
    GRANT ALL ON SCHEMA public TO ${SUPERSET_DB_USER};
EOSQL

# ------------------------------------------------------------------------------
# 3. Analytics Staging and Production Databases (Medallion Architecture for dbt & analysts)
# ------------------------------------------------------------------------------
create_user "${DBT_DB_USER}" "${DBT_DB_PASSWORD}"
create_database "${ANALYTICS_STAGING_DB}" "${DBT_DB_USER}"
create_database "${ANALYTICS_PROD_DB}" "${DBT_DB_USER}"

# Apply base privileges, Medallion schemas, and governance
for db in "${ANALYTICS_STAGING_DB}" "${ANALYTICS_PROD_DB}"; do
    echo ">>> [INIT-DBS] Granting base permissions to ${DBT_DB_USER} on ${db}..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${db}" <<-EOSQL
        GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${DBT_DB_USER};
        GRANT ALL ON SCHEMA public TO ${DBT_DB_USER};
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DBT_DB_USER};
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DBT_DB_USER};
EOSQL

    # Initialize Medallion schemas and functional roles directly
    echo ">>> [INIT-DBS] Creating Medallion schemas and applying RBAC on ${db}..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${db}" <<-EOSQL
        -- Create Medallion schemas
        CREATE SCHEMA IF NOT EXISTS bronze;
        CREATE SCHEMA IF NOT EXISTS silver;
        CREATE SCHEMA IF NOT EXISTS gold;

        -- Create functional roles globally if they do not exist
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'role_analyst') THEN
                CREATE ROLE role_analyst NOLOGIN;
            END IF;
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'role_prod_readonly') THEN
                CREATE ROLE role_prod_readonly NOLOGIN;
            END IF;
        END
        \$\$;

        ALTER ROLE role_prod_readonly SET statement_timeout = '120s';
        ALTER ROLE role_prod_readonly SET idle_in_transaction_session_timeout = '60s';

        -- Apply context-aware permissions
        DO \$\$
        DECLARE
            current_db text;
        BEGIN
            SELECT current_database() INTO current_db;

            -- role_analyst: read-only on bronze, silver, gold in staging & prod
            EXECUTE format('GRANT CONNECT ON DATABASE %I TO role_analyst', current_db);
            GRANT USAGE ON SCHEMA bronze, silver, gold TO role_analyst;
            GRANT SELECT ON ALL TABLES IN SCHEMA bronze, silver, gold TO role_analyst;
            GRANT SELECT ON ALL SEQUENCES IN SCHEMA bronze, silver, gold TO role_analyst;
            ALTER DEFAULT PRIVILEGES IN SCHEMA bronze GRANT SELECT ON TABLES TO role_analyst;
            ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO role_analyst;
            ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON TABLES TO role_analyst;

            -- role_prod_readonly: prod only
            IF current_db LIKE '%staging%' THEN
                EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM role_prod_readonly', current_db);
                REVOKE ALL ON SCHEMA bronze, silver, gold FROM role_prod_readonly;
            ELSE
                EXECUTE format('GRANT CONNECT ON DATABASE %I TO role_prod_readonly', current_db);
                GRANT USAGE ON SCHEMA bronze, silver, gold TO role_prod_readonly;
                GRANT SELECT ON ALL TABLES IN SCHEMA bronze, silver, gold TO role_prod_readonly;
                GRANT SELECT ON ALL SEQUENCES IN SCHEMA bronze, silver, gold TO role_prod_readonly;
                ALTER DEFAULT PRIVILEGES IN SCHEMA bronze GRANT SELECT ON TABLES TO role_prod_readonly;
                ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO role_prod_readonly;
                ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON TABLES TO role_prod_readonly;
            END IF;
        END
        \$\$;
EOSQL

    # Ensure dbt_runner has full creator rights on medallion schemas (bronze, silver, gold)
    echo ">>> [INIT-DBS] Ensuring ${DBT_DB_USER} can manage Medallion schemas on ${db}..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${db}" <<-EOSQL
        DO \$\$
        DECLARE
            s text;
        BEGIN
            FOR s IN SELECT schema_name FROM information_schema.schemata WHERE schema_name IN ('bronze', 'silver', 'gold') LOOP
                EXECUTE format('GRANT ALL PRIVILEGES ON SCHEMA %I TO ${DBT_DB_USER}', s);
                EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE ${DBT_DB_USER} IN SCHEMA %I GRANT ALL ON TABLES TO ${DBT_DB_USER}', s);
                EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE ${DBT_DB_USER} IN SCHEMA %I GRANT ALL ON SEQUENCES TO ${DBT_DB_USER}', s);
            END LOOP;
        END
        \$\$;
EOSQL
done

echo ">>> [INIT-DBS] All databases, Medallion schemas, and roles successfully initialized."
