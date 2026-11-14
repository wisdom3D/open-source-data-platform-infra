-- ==============================================================================
-- 01_roles_and_governance.sql - Medallion Architecture & RBAC Governance
-- Targets: analytics_staging and analytics_prod databases
-- ==============================================================================
-- Implements the Medallion architecture (bronze, silver, gold) and establishes
-- granular Role-Based Access Control (RBAC) across staging and production.
-- ==============================================================================

\echo '>>> [GOVERNANCE] Configuring Medallion schemas and functional roles...'

-- ------------------------------------------------------------------------------
-- 1. MEDALLION SCHEMAS DEFINITION
-- ------------------------------------------------------------------------------
-- bronze : Raw ingested datasets directly from ELT connectors / sources
-- silver : Cleaned, typed, enriched, and validated transformation layer
-- gold   : Curated business-level dimensional models, facts, and KPI marts

CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;

COMMENT ON SCHEMA bronze IS 'Medallion Bronze: Raw source data ingested from ELT pipelines';
COMMENT ON SCHEMA silver IS 'Medallion Silver: Cleaned, deduplicated, and conformed transformations';
COMMENT ON SCHEMA gold   IS 'Medallion Gold: Business-ready dimensional models and KPI marts';

-- ------------------------------------------------------------------------------
-- 2. FUNCTIONAL ROLES DEFINITION (NOLOGIN)
-- ------------------------------------------------------------------------------
-- role_analyst       : Data Analysts with read-only access to bronze/silver/gold across both staging and prod
-- role_prod_readonly : Business Stakeholders / BI strictly confined to analytics_prod with query timeouts

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'role_analyst') THEN
        CREATE ROLE role_analyst NOLOGIN;
    END IF;

    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'role_prod_readonly') THEN
        CREATE ROLE role_prod_readonly NOLOGIN;
    END IF;
END
$$;

-- Configure resource guardrails for role_prod_readonly (prevents runaway reporting queries)
ALTER ROLE role_prod_readonly SET statement_timeout = '120s';
ALTER ROLE role_prod_readonly SET idle_in_transaction_session_timeout = '60s';

-- ------------------------------------------------------------------------------
-- 3. RBAC PERMISSIONS MATRIX (CONTEXT-AWARE BASED ON CURRENT DATABASE)
-- ------------------------------------------------------------------------------
DO $$
DECLARE
    current_db text;
BEGIN
    SELECT current_database() INTO current_db;
    RAISE NOTICE '>>> Applying RBAC governance rules for database: %', current_db;

    -- =========================================================================
    -- A. PERMISSIONS FOR role_analyst (Both Staging and Production)
    -- =========================================================================
    -- Analysts must have read-only access to all medallion layers for debugging and auditing
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO role_analyst', current_db);
    GRANT USAGE ON SCHEMA bronze, silver, gold TO role_analyst;
    GRANT SELECT ON ALL TABLES IN SCHEMA bronze, silver, gold TO role_analyst;
    GRANT SELECT ON ALL SEQUENCES IN SCHEMA bronze, silver, gold TO role_analyst;

    -- Default privileges for future dbt builds / tables
    ALTER DEFAULT PRIVILEGES IN SCHEMA bronze GRANT SELECT ON TABLES TO role_analyst;
    ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO role_analyst;
    ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON TABLES TO role_analyst;
    ALTER DEFAULT PRIVILEGES IN SCHEMA bronze GRANT SELECT ON SEQUENCES TO role_analyst;
    ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON SEQUENCES TO role_analyst;
    ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON SEQUENCES TO role_analyst;

    -- =========================================================================
    -- B. PERMISSIONS FOR role_prod_readonly (Production ONLY)
    -- =========================================================================
    IF current_db LIKE '%staging%' THEN
        -- Strictly revoke and deny any access to staging environments for prod_readonly
        RAISE NOTICE '>>> Staging environment detected (%): Revoking all access from role_prod_readonly', current_db;
        EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM role_prod_readonly', current_db);
        REVOKE ALL ON SCHEMA bronze, silver, gold FROM role_prod_readonly;
    ELSE
        -- Production environment: Read-only access to all medallion schemas with timeouts
        RAISE NOTICE '>>> Production environment detected (%): Granting read-only access to role_prod_readonly', current_db;
        EXECUTE format('GRANT CONNECT ON DATABASE %I TO role_prod_readonly', current_db);
        GRANT USAGE ON SCHEMA bronze, silver, gold TO role_prod_readonly;
        GRANT SELECT ON ALL TABLES IN SCHEMA bronze, silver, gold TO role_prod_readonly;
        GRANT SELECT ON ALL SEQUENCES IN SCHEMA bronze, silver, gold TO role_prod_readonly;

        ALTER DEFAULT PRIVILEGES IN SCHEMA bronze GRANT SELECT ON TABLES TO role_prod_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON TABLES TO role_prod_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON TABLES TO role_prod_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA bronze GRANT SELECT ON SEQUENCES TO role_prod_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA silver GRANT SELECT ON SEQUENCES TO role_prod_readonly;
        ALTER DEFAULT PRIVILEGES IN SCHEMA gold   GRANT SELECT ON SEQUENCES TO role_prod_readonly;
    END IF;
END
$$;

\echo '>>> [GOVERNANCE] Medallion schemas and RBAC governance successfully applied.'
