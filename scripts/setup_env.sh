#!/usr/bin/env bash
# ==============================================================================
# setup_env.sh - Interactive Environment Configuration Assistant
# Open Source Modern Data Platform
# ==============================================================================
# Prompts for domains and paths, generates strong cryptographic secrets,
# and outputs a hardened .env file with permissions 600.
# ==============================================================================

set -euo pipefail

# Visual formatting helpers
BOLD="\033[1m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
CYAN="\033[1;36m"
RED="\033[1;31m"
RESET="\033[0m"

log_info()    { echo -e "${GREEN}✓${RESET} $*"; }
log_step()    { echo -e "\n${BLUE}===>${RESET} ${BOLD}$*${RESET}"; }
log_warning() { echo -e "${YELLOW}⚠${RESET} $*"; }
log_error()   { echo -e "${RED}✖ [ERROR]${RESET} $*" >&2; }

# Locate project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

echo -e "${CYAN}========================================================================${RESET}"
echo -e "${BOLD}  ⚙️  Open Source Data Platform - Interactive Setup Wizard${RESET}"
echo -e "${CYAN}========================================================================${RESET}"
echo "This assistant will configure your '.env' file with production-ready"
echo "settings and auto-generate cryptographically secure passwords and keys."
echo ""

# Check if an existing .env file is present
if [[ -f "$ENV_FILE" ]]; then
    log_warning "An existing '.env' file was found at: $ENV_FILE"
    if [[ -t 0 ]]; then
        read -r -p "Do you want to overwrite it and regenerate all secrets? [y/N]: " confirm_overwrite
        if [[ ! "$confirm_overwrite" =~ ^[Yy]$ ]]; then
            echo -e "Aborting setup. Existing '.env' was preserved."
            exit 0
        fi
        BACKUP_ENV="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$ENV_FILE" "$BACKUP_ENV"
        log_info "Backup of existing .env saved to: $BACKUP_ENV"
    fi
fi

# ------------------------------------------------------------------------------
# 1. INTERACTIVE INPUT (Mandatory & Optional parameters)
# ------------------------------------------------------------------------------
log_step "1/3 : Public Domain Names Configuration"
echo "Please provide your FQDN domains (pointing to your VPS public IP via DNS Type A):"

# Airflow Domain
DEFAULT_AIRFLOW_DOMAIN="elt.example.com"
if [[ -t 0 ]]; then
    read -r -p "  Enter Airflow Web Domain [ex: elt.mydomain.com]: " INPUT_AIRFLOW_DOMAIN
    AIRFLOW_DOMAIN="${INPUT_AIRFLOW_DOMAIN:-$DEFAULT_AIRFLOW_DOMAIN}"
else
    AIRFLOW_DOMAIN="${AIRFLOW_DOMAIN:-$DEFAULT_AIRFLOW_DOMAIN}"
fi
log_info "Airflow Domain: ${BOLD}${AIRFLOW_DOMAIN}${RESET}"

# Superset Domain
DEFAULT_SUPERSET_DOMAIN="bi.example.com"
if [[ -t 0 ]]; then
    read -r -p "  Enter Superset Web Domain [ex: bi.mydomain.com]: " INPUT_SUPERSET_DOMAIN
    SUPERSET_DOMAIN="${INPUT_SUPERSET_DOMAIN:-$DEFAULT_SUPERSET_DOMAIN}"
else
    SUPERSET_DOMAIN="${SUPERSET_DOMAIN:-$DEFAULT_SUPERSET_DOMAIN}"
fi
log_info "Superset Domain: ${BOLD}${SUPERSET_DOMAIN}${RESET}"

log_step "2/3 : Ports & Paths Configuration"

# PostgreSQL Loopback Host Port
DEFAULT_POSTGRES_PORT="5433"
if [[ -t 0 ]]; then
    echo "  Port 5432 is reserved for local host PostgreSQL instances."
    read -r -p "  Enter PostgreSQL host port on 127.0.0.1 [default: 5433]: " INPUT_POSTGRES_PORT
    POSTGRES_HOST_PORT="${INPUT_POSTGRES_PORT:-$DEFAULT_POSTGRES_PORT}"
else
    POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-$DEFAULT_POSTGRES_PORT}"
fi
log_info "PostgreSQL Loopback Port: ${BOLD}${POSTGRES_HOST_PORT}${RESET}"

# External dbt Project Directory
DEFAULT_DBT_PATH="/opt/dbt-analytics"
if [[ -t 0 ]]; then
    read -r -p "  Enter absolute host path for external dbt repo [default: /opt/dbt-analytics]: " INPUT_DBT_PATH
    DBT_PROJECT_HOST_PATH="${INPUT_DBT_PATH:-$DEFAULT_DBT_PATH}"
else
    DBT_PROJECT_HOST_PATH="${DBT_PROJECT_HOST_PATH:-$DEFAULT_DBT_PATH}"
fi
log_info "dbt Host Path: ${BOLD}${DBT_PROJECT_HOST_PATH}${RESET}"

# Admin Email
DEFAULT_ADMIN_EMAIL="admin@example.com"
if [[ -t 0 ]]; then
    read -r -p "  Enter Administrator Email [default: admin@example.com]: " INPUT_ADMIN_EMAIL
    ADMIN_EMAIL="${INPUT_ADMIN_EMAIL:-$DEFAULT_ADMIN_EMAIL}"
else
    ADMIN_EMAIL="${ADMIN_EMAIL:-$DEFAULT_ADMIN_EMAIL}"
fi
log_info "Admin Email: ${BOLD}${ADMIN_EMAIL}${RESET}"

# ------------------------------------------------------------------------------
# 2. AUTOMATIC SECRET GENERATION (OpenSSL & Cryptography)
# ------------------------------------------------------------------------------
log_step "3/3 : Generating Cryptographic Secrets & Strong Passwords"

if ! command -v openssl >/dev/null 2>&1; then
    log_error "OpenSSL is required to generate secure random keys. Please install openssl."
    exit 1
fi

# Passwords (32-character hex = 128 bits of high entropy, safe for SQL/URLs)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
AIRFLOW_DB_PASSWORD=$(openssl rand -hex 16)
SUPERSET_DB_PASSWORD=$(openssl rand -hex 16)
DBT_DB_PASSWORD=$(openssl rand -hex 16)
AIRFLOW_ADMIN_PASSWORD=$(openssl rand -hex 16)
SUPERSET_ADMIN_PASSWORD=$(openssl rand -hex 16)

# Cryptographic Session & Fernet Keys
AIRFLOW_SECRET_KEY=$(openssl rand -hex 32)
SUPERSET_SECRET_KEY=$(openssl rand -base64 42)

# Airflow Fernet Key (Standard 32-byte URL-safe base64 key with '=' padding)
if command -v python3 >/dev/null 2>&1 && python3 -c "import cryptography" >/dev/null 2>&1; then
    AIRFLOW_FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
else
    # Fallback to standard 32-byte base64 generated with OpenSSL (RFC 4648 URL-safe compliant)
    AIRFLOW_FERNET_KEY=$(openssl rand -base64 32)
fi

log_info "Database passwords and application encryption keys generated."

# ------------------------------------------------------------------------------
# 3. WRITE HARDENED .env FILE
# ------------------------------------------------------------------------------
cat <<EOF > "$ENV_FILE"
# ==============================================================================
# OPEN-SOURCE DATA PLATFORM INFRASTRUCTURE - ACTIVE CONFIGURATION (.env)
# Generated automatically by scripts/setup_env.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ==============================================================================

# ==============================================================================
# [OBLIGATOIRE] 1. DOMAINES PUBLICS & REVERSE PROXY NGINX
# ==============================================================================
AIRFLOW_DOMAIN=${AIRFLOW_DOMAIN}
SUPERSET_DOMAIN=${SUPERSET_DOMAIN}

# ==============================================================================
# [OBLIGATOIRE / AUTO-GENERE] 2. SECRETS CRYPTOGRAPHIQUES & MOTS DE PASSE
# ==============================================================================
# --- Clés Cryptographiques Applicatives ---
AIRFLOW__CORE__FERNET_KEY=${AIRFLOW_FERNET_KEY}
AIRFLOW__WEBSERVER__SECRET_KEY=${AIRFLOW_SECRET_KEY}
SUPERSET_SECRET_KEY=${SUPERSET_SECRET_KEY}

# --- Mots de Passe Bases de Données PostgreSQL ---
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}

AIRFLOW_DB_USER=airflow
AIRFLOW_DB_PASSWORD=${AIRFLOW_DB_PASSWORD}

SUPERSET_DB_USER=superset
SUPERSET_DB_PASSWORD=${SUPERSET_DB_PASSWORD}

DBT_DB_USER=dbt_runner
DBT_DB_PASSWORD=${DBT_DB_PASSWORD}

# --- Comptes Administrateurs Web Initiaux ---
_AIRFLOW_WWW_USER_USERNAME=admin
_AIRFLOW_WWW_USER_PASSWORD=${AIRFLOW_ADMIN_PASSWORD}
_AIRFLOW_WWW_USER_EMAIL=${ADMIN_EMAIL}
_AIRFLOW_WWW_USER_FIRSTNAME=Platform
_AIRFLOW_WWW_USER_LASTNAME=Admin

SUPERSET_ADMIN_USERNAME=admin
SUPERSET_ADMIN_PASSWORD=${SUPERSET_ADMIN_PASSWORD}
SUPERSET_ADMIN_EMAIL=${ADMIN_EMAIL}
SUPERSET_ADMIN_FIRSTNAME=Superset
SUPERSET_ADMIN_LASTNAME=Admin

# ==============================================================================
# [OPTIONNEL] 3. PORTS D'ECOUTE, CHEMINS SYSTEME & PARAMETRES AVANCES
# ==============================================================================
POSTGRES_HOST_PORT=${POSTGRES_HOST_PORT}
AIRFLOW_HOST_PORT=8080
SUPERSET_HOST_PORT=8088

DBT_PROJECT_HOST_PATH=${DBT_PROJECT_HOST_PATH}
AIRFLOW_UID=50000

POSTGRES_DB=postgres
AIRFLOW_DB=airflow_backend
SUPERSET_DB=superset
ANALYTICS_STAGING_DB=analytics_staging
ANALYTICS_PROD_DB=analytics_prod

SUPERSET_ROW_LIMIT=50000

DBT_TARGET=prod
DBT_PROD_HOST=postgres
DBT_PROD_PORT=5432
DBT_PROD_DB=analytics_prod
DBT_PROD_SCHEMA=public
EOF

# Enforce strict file permissions (Read/Write for owner only)
chmod 600 "$ENV_FILE"
log_info "Hardened permissions: chmod 600 applied to ${ENV_FILE}"

# ------------------------------------------------------------------------------
# 4. CREDENTIALS SUMMARY DISPLAY
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================================================${RESET}"
echo -e "${BOLD}  🎉 Environment File (.env) Successfully Generated!${RESET}"
echo -e "${GREEN}========================================================================${RESET}"
echo -e "${YELLOW}IMPORTANT: Save the credentials below into your password manager!${RESET}"
echo "------------------------------------------------------------------------"
echo -e "${BOLD}1. Apache Airflow Web UI :${RESET}"
echo -e "   URL      : http://${AIRFLOW_DOMAIN}"
echo -e "   Username : ${BOLD}admin${RESET}"
echo -e "   Password : ${GREEN}${AIRFLOW_ADMIN_PASSWORD}${RESET}"
echo ""
echo -e "${BOLD}2. Apache Superset Web UI :${RESET}"
echo -e "   URL      : http://${SUPERSET_DOMAIN}"
echo -e "   Username : ${BOLD}admin${RESET}"
echo -e "   Password : ${GREEN}${SUPERSET_ADMIN_PASSWORD}${RESET}"
echo ""
echo -e "${BOLD}3. PostgreSQL Master & Service Accounts :${RESET}"
echo -e "   Host (Loopback) : 127.0.0.1:${POSTGRES_HOST_PORT}"
echo -e "   postgres (root) : ${POSTGRES_PASSWORD}"
echo -e "   dbt_runner      : ${DBT_DB_PASSWORD}"
echo -e "   airflow         : ${AIRFLOW_DB_PASSWORD}"
echo -e "   superset        : ${SUPERSET_DB_PASSWORD}"
echo "------------------------------------------------------------------------"
echo -e "${CYAN}Next Step: Run the One-Click Deployment script:${RESET}"
echo -e "   ${BOLD}sudo ./deploy.sh${RESET}"
echo -e "${GREEN}========================================================================${RESET}"
echo ""

