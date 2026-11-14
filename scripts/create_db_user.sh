#!/usr/bin/env bash
# ==============================================================================
# create_db_user.sh - Automated PostgreSQL User, Role & Sandbox Provisioning
# Target: PostgreSQL 16 container (data_platform_postgres)
# ==============================================================================
# Usage:
#   ./scripts/create_db_user.sh <username> <role>
#
# Arguments:
#   <username> : Name of the PostgreSQL user to create (lowercase alphanumeric + _)
#   <role>     : Functional role: 'role_analyst' or 'role_prod_readonly'
#
# Behavior:
#   - role_analyst       : Read-only access to bronze/silver/gold across both
#                          analytics_staging and analytics_prod.
#                          Creates dedicated sandbox schema '<username>_dev' in
#                          analytics_staging with ownership, while sharing read
#                          access to all peers in role_analyst.
#   - role_prod_readonly : Restricted strictly to analytics_prod (bronze/silver/gold)
#                          with guardrail timeouts (statement: 120s, idle: 60s).
# ==============================================================================

set -euo pipefail

# Visual log helpers
log_info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

CONTAINER_NAME="data_platform_postgres"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Display usage helper if required arguments are missing
if [[ $# -lt 2 ]]; then
    echo "========================================================================"
    echo "  PostgreSQL User, RBAC Role & Developer Sandbox Provisioning"
    echo "========================================================================"
    echo "Usage:   $0 <username> <role>"
    echo ""
    echo "Available Roles:"
    echo "  - role_analyst       : Read-only on bronze/silver/gold (staging & prod)"
    echo "                         + Dedicated sandbox '<username>_dev' in staging"
    echo "  - role_prod_readonly : Read-only on bronze/silver/gold (prod only, with timeouts)"
    echo ""
    echo "Examples:"
    echo "  $0 alice role_analyst"
    echo "  $0 bob role_prod_readonly"
    echo "========================================================================"
    exit 1
fi

USERNAME="$1"
ROLE="$2"

# Sanitize username (alphanumeric + underscore only)
if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_]*$ ]]; then
    log_err "Invalid username '$USERNAME'. Must match ^[a-z_][a-z0-9_]*$ (lowercase letters, numbers, underscore)"
    exit 1
fi

# Validate role argument
if [[ "$ROLE" != "role_analyst" ]] && [[ "$ROLE" != "role_prod_readonly" ]]; then
    log_err "Invalid role '$ROLE'. Supported roles: 'role_analyst' or 'role_prod_readonly'"
    exit 1
fi

# Load environment defaults if available
POSTGRES_USER="postgres"
STAGING_DB="analytics_staging"
PROD_DB="analytics_prod"
POSTGRES_HOST_PORT="5433"

if [[ -f "$ENV_FILE" ]]; then
    POSTGRES_USER=$(grep -E '^POSTGRES_USER=' "$ENV_FILE" | cut -d '=' -f2 | tr -d ' "\r\n' || echo "postgres")
    STAGING_DB=$(grep -E '^ANALYTICS_STAGING_DB=' "$ENV_FILE" | cut -d '=' -f2 | tr -d ' "\r\n' || echo "analytics_staging")
    PROD_DB=$(grep -E '^ANALYTICS_PROD_DB=' "$ENV_FILE" | cut -d '=' -f2 | tr -d ' "\r\n' || echo "analytics_prod")
    POSTGRES_HOST_PORT=$(grep -E '^POSTGRES_HOST_PORT=' "$ENV_FILE" | cut -d '=' -f2 | tr -d ' "\r\n' || echo "5433")
fi

# 1. Verify Docker CLI and container status
if ! command -v docker >/dev/null 2>&1; then
    log_err "Docker CLI is not found on this system. Please ensure docker is installed."
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log_err "Container '${CONTAINER_NAME}' is not running! Start it with: docker compose up -d postgres"
    exit 1
fi

# 2. Generate a secure random password (32 hex characters = 128-bit entropy)
PASSWORD=$(openssl rand -hex 16)

log_info "Creating/updating global user '$USERNAME' in PostgreSQL..."

# 3. Create or update user globally on the cluster
docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$PROD_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${USERNAME}') THEN
            CREATE USER ${USERNAME} WITH PASSWORD '${PASSWORD}';
        ELSE
            ALTER USER ${USERNAME} WITH PASSWORD '${PASSWORD}';
        END IF;
    END
    \$\$;
EOSQL

DEV_SCHEMA=""

# 4. Role-specific configuration & sandbox creation
if [[ "$ROLE" == "role_analyst" ]]; then
    DEV_SCHEMA="${USERNAME}_dev"
    log_info "Configuring 'role_analyst' across '${STAGING_DB}' and '${PROD_DB}'..."

    # A. Configure Staging: Connect + role_analyst + Dedicated Sandbox Schema
    log_info "Creating developer sandbox '${DEV_SCHEMA}' in '${STAGING_DB}'..."
    docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$STAGING_DB" <<-EOSQL
        -- Allow connection and grant role
        GRANT CONNECT ON DATABASE ${STAGING_DB} TO ${USERNAME};
        GRANT role_analyst TO ${USERNAME};

        -- Create dedicated analyst dev schema with ownership
        CREATE SCHEMA IF NOT EXISTS "${DEV_SCHEMA}" AUTHORIZATION ${USERNAME};
        COMMENT ON SCHEMA "${DEV_SCHEMA}" IS 'Personal development and scratchpad schema for analyst ${USERNAME}';

        -- Allow peers in role_analyst to read this schema for collaboration and peer-review
        GRANT USAGE ON SCHEMA "${DEV_SCHEMA}" TO role_analyst;
        GRANT SELECT ON ALL TABLES IN SCHEMA "${DEV_SCHEMA}" TO role_analyst;
        GRANT SELECT ON ALL SEQUENCES IN SCHEMA "${DEV_SCHEMA}" TO role_analyst;
        ALTER DEFAULT PRIVILEGES FOR ROLE ${USERNAME} IN SCHEMA "${DEV_SCHEMA}" GRANT SELECT ON TABLES TO role_analyst;
        ALTER DEFAULT PRIVILEGES FOR ROLE ${USERNAME} IN SCHEMA "${DEV_SCHEMA}" GRANT SELECT ON SEQUENCES TO role_analyst;
EOSQL

    # B. Configure Production: Connect + role_analyst (read-only on bronze, silver, gold)
    log_info "Granting audit and read-only access to '${PROD_DB}'..."
    docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$PROD_DB" <<-EOSQL
        GRANT CONNECT ON DATABASE ${PROD_DB} TO ${USERNAME};
        GRANT role_analyst TO ${USERNAME};
EOSQL

elif [[ "$ROLE" == "role_prod_readonly" ]]; then
    log_info "Configuring 'role_prod_readonly' strictly on '${PROD_DB}'..."

    # Production grant only
    docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$PROD_DB" <<-EOSQL
        GRANT CONNECT ON DATABASE ${PROD_DB} TO ${USERNAME};
        GRANT role_prod_readonly TO ${USERNAME};
EOSQL

    # Ensure staging connection is explicitly denied
    docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$STAGING_DB" <<-EOSQL
        REVOKE CONNECT ON DATABASE ${STAGING_DB} FROM ${USERNAME};
EOSQL
fi

# 5. Output formatted credentials and onboarding summary
echo ""
echo "========================================================================"
echo -e "\033[1;32m✓ PostgreSQL User Successfully Configured!\033[0m"
echo "========================================================================"
echo "  Username        : ${USERNAME}"
echo "  Generated Pass  : ${PASSWORD}"
echo "  Assigned Role   : ${ROLE}"
echo "  Host / Port     : 127.0.0.1:${POSTGRES_HOST_PORT} (via SSH Tunnel)"
echo ""
if [[ "$ROLE" == "role_analyst" ]]; then
    echo "  Accessible Databases :"
    echo "    1. ${STAGING_DB} -> Read: bronze, silver, gold | Write (Owner): ${DEV_SCHEMA}"
    echo "    2. ${PROD_DB}    -> Read: bronze, silver, gold (Audit / Debug)"
    echo "  Personal Sandbox     : ${DEV_SCHEMA} (in ${STAGING_DB})"
else
    echo "  Accessible Database  :"
    echo "    1. ${PROD_DB}    -> Read: bronze, silver, gold (Production only)"
    echo "  Query Timeouts       : statement_timeout=120s, idle_in_transaction=60s"
fi
echo "========================================================================"
echo "Next Steps:"
echo "  1. Provision the matching SSH tunnel account (if not already done):"
echo "       sudo ./scripts/setup_ssh_users.sh ${USERNAME}"
echo "  2. Share credentials securely and guide the user via DBeaver documentation:"
echo "       👉 docs/dbeaver-ssh-onboarding.md"
echo "========================================================================"
echo ""
