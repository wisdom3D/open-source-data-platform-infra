# ==============================================================================
# Apache Superset 4.0.1 - Global Configuration
# ==============================================================================
import os

# ------------------------------------------------------------------------------
# 1. CORE & SECURITY CONFIGURATION
# ------------------------------------------------------------------------------
SECRET_KEY = os.environ.get(
    "SUPERSET_SECRET_KEY", 
    "THIS_IS_A_FALLBACK_KEY_REPLACE_IN_PRODUCTION_ENV_IMMEDIATELY"
)

# Metadata Database URI (PostgreSQL backend)
SQLALCHEMY_DATABASE_URI = os.environ.get(
    "SUPERSET_SQLALCHEMY_DATABASE_URI",
    "postgresql+psycopg2://superset:superset@postgres:5432/superset"
)

# ------------------------------------------------------------------------------
# 2. QUERY & SQL LAB LIMITS
# ------------------------------------------------------------------------------
# Maximum number of rows returned in SQL Lab and Charts
ROW_LIMIT = int(os.environ.get("SUPERSET_ROW_LIMIT", 50000))

# SQL Lab query execution timeout (seconds)
SQLLAB_ASYNC_TIME_LIMIT_SEC = 300
SUPERSET_WEBSERVER_TIMEOUT = 120

# ------------------------------------------------------------------------------
# 3. FEATURE FLAGS
# ------------------------------------------------------------------------------
# Mandatory requirement: Enable Jinja templating in SQL queries
ENABLE_TEMPLATE_PROCESSING = True

FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
    "DASHBOARD_NATIVE_FILTERS": True,
    "EMBEDDED_SUPERSET": True,
    "ALERT_REPORTS": False,
}

# ------------------------------------------------------------------------------
# 4. PROXY & REVERSE PROXY / SSH TUNNEL COMPATIBILITY
# ------------------------------------------------------------------------------
# Ensures session cookies and CSRF behave properly through SSH local port forwarding (127.0.0.1)
ENABLE_PROXY_FIX = True
TALISMAN_ENABLED = False  # Disabled strict CSP for local SSH tunnel access
WTF_CSRF_ENABLED = True
WTF_CSRF_TIME_LIMIT = 60 * 60 * 24 * 7  # 7 days

# Webserver settings
SUPERSET_WEBSERVER_PORT = 8088
SUPERSET_WORKERS = 2  # Optimized for 4 vCPU VPS

# Cache configuration (default in-memory / fallback)
CACHE_CONFIG = {
    "CACHE_TYPE": "SimpleCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
}
DATA_CACHE_CONFIG = CACHE_CONFIG

