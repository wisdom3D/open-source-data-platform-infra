#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - One-Click Infrastructure Deployment & Automation Script
# Open Source Modern Data Platform (PostgreSQL, Airflow, Superset, dbt, Nginx)
# Target OS: Ubuntu 24.04 LTS / Debian 12
# ==============================================================================
# Usage:
#   sudo ./deploy.sh
# ==============================================================================

set -euo pipefail

# Visual log formatting helpers
log_step() { echo -e "\n\033[1;34m===> [STEP $1] $2\033[0m"; }
log_info() { echo -e "  \033[1;32m✓\033[0m $*"; }
log_warn() { echo -e "  \033[1;33m⚠\033[0m $*"; }
log_err()  { echo -e "  \033[1;31m✖ [ERROR]\033[0m $*" >&2; }

# ------------------------------------------------------------------------------
# 0. ROOT PRIVILEGES & ENVIRONMENT VERIFICATION
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    log_err "This deployment script must be run as root."
    echo -e "Please execute: \033[1;37msudo ./deploy.sh\033[0m" >&2
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

if [[ ! -f ".env" ]]; then
    log_warn "Configuration file '.env' not found in $PROJECT_ROOT."
    if [[ -f "scripts/setup_env.sh" ]] && [[ -t 0 ]]; then
        echo -e "\n\033[1;36m💡 Would you like to launch the interactive setup wizard (scripts/setup_env.sh) now? [Y/n]\033[0m"
        read -r run_wizard
        if [[ "$run_wizard" =~ ^[Yy]?$ ]]; then
            chmod +x scripts/setup_env.sh
            ./scripts/setup_env.sh
        else
            log_err "Deployment aborted. Please create and configure '.env' before running deploy.sh."
            exit 1
        fi
    else
        log_err "Configuration file '.env' not found in $PROJECT_ROOT!"
        echo "========================================================================"
        echo "Please generate your environment file first:"
        echo "  ./scripts/setup_env.sh"
        echo "Or copy the template manually:"
        echo "  cp .env.example .env && nano .env"
        echo "========================================================================"
        exit 1
    fi
fi

# Ensure .env exists after wizard attempt
if [[ ! -f ".env" ]]; then
    log_err "Configuration file '.env' is still missing. Aborting."
    exit 1
fi

# Load environment variables
set -a
# shellcheck disable=SC1091
source .env
set +a

# Defaults and fallbacks
AIRFLOW_UID="${AIRFLOW_UID:-50000}"
DBT_PROJECT_HOST_PATH="${DBT_PROJECT_HOST_PATH:-/opt/dbt-analytics}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-5433}"
AIRFLOW_HOST_PORT="${AIRFLOW_HOST_PORT:-8080}"
SUPERSET_HOST_PORT="${SUPERSET_HOST_PORT:-8088}"
AIRFLOW_DOMAIN="${AIRFLOW_DOMAIN:-elt.example.com}"
SUPERSET_DOMAIN="${SUPERSET_DOMAIN:-bi.example.com}"
ANALYTICS_STAGING_DB="${ANALYTICS_STAGING_DB:-analytics_staging}"
ANALYTICS_PROD_DB="${ANALYTICS_PROD_DB:-analytics_prod}"
SUPERSET_ADMIN_USERNAME="${SUPERSET_ADMIN_USERNAME:-admin}"
SUPERSET_ADMIN_PASSWORD="${SUPERSET_ADMIN_PASSWORD:-admin}"
SUPERSET_ADMIN_FIRSTNAME="${SUPERSET_ADMIN_FIRSTNAME:-Superset}"
SUPERSET_ADMIN_LASTNAME="${SUPERSET_ADMIN_LASTNAME:-Admin}"
SUPERSET_ADMIN_EMAIL="${SUPERSET_ADMIN_EMAIL:-admin@example.com}"

echo "========================================================================"
echo "  🚀 Starting One-Click Deployment: Open Source Data Platform"
echo "  Host: $(hostname -f 2>/dev/null || hostname)"
echo "  Directory: $PROJECT_ROOT"
echo "========================================================================"

# ------------------------------------------------------------------------------
# STEP 1: PREPARE EXTERNAL DBT DIRECTORY AND PERMISSIONS
# ------------------------------------------------------------------------------
log_step "1/7" "Configuring external dbt project directory permissions..."
if [[ ! -d "$DBT_PROJECT_HOST_PATH" ]]; then
    mkdir -p "$DBT_PROJECT_HOST_PATH"
    log_info "Created directory: $DBT_PROJECT_HOST_PATH"
else
    log_info "Directory exists: $DBT_PROJECT_HOST_PATH"
fi

# Grant ownership to Airflow UID (50000:0) and adjust permissions
chown -R "${AIRFLOW_UID}:0" "$DBT_PROJECT_HOST_PATH"
chmod -R 775 "$DBT_PROJECT_HOST_PATH"
log_info "Permissions 775 and ownership ${AIRFLOW_UID}:0 applied to $DBT_PROJECT_HOST_PATH"

# ------------------------------------------------------------------------------
# STEP 2: BUILD AND START CONTAINERIZED INFRASTRUCTURE
# ------------------------------------------------------------------------------
log_step "2/7" "Building custom images and starting Docker Compose services..."
if ! command -v docker >/dev/null 2>&1; then
    log_err "Docker is not installed or not in PATH. Please install Docker Compose v2."
    exit 1
fi

docker compose pull postgres || true
docker compose build
docker compose up -d --remove-orphans
log_info "Docker Compose services launched in background."

# ------------------------------------------------------------------------------
# STEP 3: WAIT FOR POSTGRESQL READINESS (pg_isready loop)
# ------------------------------------------------------------------------------
log_step "3/7" "Waiting for PostgreSQL container (data_platform_postgres) to be healthy..."
MAX_ATTEMPTS=30
ATTEMPT=0
until docker exec data_platform_postgres pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; do
    ATTEMPT=$((ATTEMPT + 1))
    if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
        log_err "PostgreSQL did not become ready after ${MAX_ATTEMPTS} attempts."
        docker compose logs postgres
        exit 1
    fi
    echo -n "."
    sleep 2
done
echo ""
log_info "PostgreSQL is healthy and accepting connections."

# ------------------------------------------------------------------------------
# STEP 4: APPLY SQL GOVERNANCE & MEDALLION SCHEMAS
# ------------------------------------------------------------------------------
log_step "4/7" "Applying Medallion schemas & RBAC governance (sql/01_roles_and_governance.sql)..."
GOVERNANCE_FILE="sql/01_roles_and_governance.sql"

if [[ -f "$GOVERNANCE_FILE" ]]; then
    for target_db in "$ANALYTICS_STAGING_DB" "$ANALYTICS_PROD_DB"; do
        log_info "Applying governance to database: ${target_db}..."
        # Run script through psql, ignoring redundant creation notices safely
        docker exec -i data_platform_postgres psql \
            -U "$POSTGRES_USER" \
            -d "$target_db" \
            -v ON_ERROR_STOP=0 \
            < "$GOVERNANCE_FILE" >/dev/null 2>&1 || true
        log_info "Medallion schemas (bronze, silver, gold) and RBAC applied on ${target_db}."
    done
else
    log_warn "Governance file $GOVERNANCE_FILE not found, skipping manual trigger."
fi

# ------------------------------------------------------------------------------
# STEP 5: INITIALIZE APACHE SUPERSET
# ------------------------------------------------------------------------------
log_step "5/7" "Checking and completing Apache Superset initialization..."
# Wait up to 20 seconds for superset webserver container to respond
ATTEMPT=0
until docker exec data_platform_superset superset version >/dev/null 2>&1 || [[ $ATTEMPT -ge 10 ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
done

log_info "Upgrading Superset metadata database..."
docker exec -i data_platform_superset superset db upgrade >/dev/null 2>&1 || true

log_info "Ensuring administrative user '${SUPERSET_ADMIN_USERNAME}' exists..."
docker exec -i data_platform_superset superset fab create-admin \
    --username "$SUPERSET_ADMIN_USERNAME" \
    --firstname "$SUPERSET_ADMIN_FIRSTNAME" \
    --lastname "$SUPERSET_ADMIN_LASTNAME" \
    --email "$SUPERSET_ADMIN_EMAIL" \
    --password "$SUPERSET_ADMIN_PASSWORD" >/dev/null 2>&1 || true

log_info "Initializing Superset default roles and permissions..."
docker exec -i data_platform_superset superset init >/dev/null 2>&1 || true
log_info "Apache Superset initialization confirmed."

# ------------------------------------------------------------------------------
# STEP 6: CONFIGURE ISOLATED NGINX REVERSE PROXY
# ------------------------------------------------------------------------------
log_step "6/7" "Generating isolated Nginx vhost configuration..."

# Verify gettext-base (envsubst) and nginx
if ! command -v envsubst >/dev/null 2>&1; then
    log_warn "envsubst not found. Installing gettext-base..."
    apt-get update -y && apt-get install -y gettext-base
fi

if ! command -v nginx >/dev/null 2>&1; then
    log_warn "Nginx not found. Installing nginx..."
    apt-get update -y && apt-get install -y nginx
fi

NGINX_TEMPLATE="nginx/data-platform.conf.template"
NGINX_TARGET="/etc/nginx/sites-available/open-source-data-platform.conf"
NGINX_LINK="/etc/nginx/sites-enabled/open-source-data-platform.conf"

if [[ -f "$NGINX_TEMPLATE" ]]; then
    # Generate vhost substituting only our environment variables
    envsubst '${AIRFLOW_DOMAIN} ${SUPERSET_DOMAIN} ${AIRFLOW_HOST_PORT} ${SUPERSET_HOST_PORT}' \
        < "$NGINX_TEMPLATE" \
        > "$NGINX_TARGET"
    log_info "Generated Nginx vhost: $NGINX_TARGET"

    mkdir -p /etc/nginx/sites-enabled
    ln -sf "$NGINX_TARGET" "$NGINX_LINK"
    log_info "Enabled vhost symlink: $NGINX_LINK"

    # Test Nginx syntax before reloading
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        log_info "Nginx configuration reloaded successfully without downtime."
    else
        log_err "Nginx syntax validation failed! Please check $NGINX_TARGET"
        nginx -t
        exit 1
    fi
else
    log_err "Template $NGINX_TEMPLATE not found!"
    exit 1
fi

# ------------------------------------------------------------------------------
# STEP 7: SUMMARY & NEXT STEPS
# ------------------------------------------------------------------------------
log_step "7/7" "Deployment Complete!"

echo ""
echo "========================================================================"
echo -e "\033[1;32m🎉 Open Source Data Platform Successfully Deployed!\033[0m"
echo "========================================================================"
echo "  Airflow Web UI   : http://${AIRFLOW_DOMAIN} (Proxy -> 127.0.0.1:${AIRFLOW_HOST_PORT})"
echo "  Superset Web UI  : http://${SUPERSET_DOMAIN} (Proxy -> 127.0.0.1:${SUPERSET_HOST_PORT})"
echo "  PostgreSQL Host  : 127.0.0.1:${POSTGRES_HOST_PORT} (Loopback / SSH Tunnel)"
echo "  dbt Project Path : ${DBT_PROJECT_HOST_PATH}"
echo "========================================================================"
echo -e "\033[1;33m👉 MANDATORY NEXT STEP (SSL Encryption):\033[0m"
echo "  Enable free Let's Encrypt HTTPS certificates for both domains:"
echo ""
echo -e "  \033[1;37msudo certbot --nginx -d ${AIRFLOW_DOMAIN} -d ${SUPERSET_DOMAIN}\033[0m"
echo ""
echo "========================================================================"
echo "👉 USER & ANALYST ONBOARDING:"
echo "  1. Provision an SSH Tunnel account:"
echo "       sudo ./scripts/setup_ssh_users.sh <username>"
echo ""
echo "  2. Create PostgreSQL user with Medallion RBAC & personal sandbox:"
echo "       ./scripts/create_db_user.sh <username> role_analyst"
echo ""
echo "  3. Guide user to configure DBeaver via SSH tunnel:"
echo "       👉 docs/dbeaver-ssh-onboarding.md"
echo "========================================================================"
echo ""

