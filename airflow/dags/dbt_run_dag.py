"""
### dbt Production Orchestration DAG
Orchestrates dbt transformations using native Airflow `BashOperator`.
Target project is mounted at `/opt/airflow/dbt_project` from the host VPS.
"""

from datetime import datetime, timedelta
import os
from airflow import DAG
from airflow.operators.bash import BashOperator

# Default arguments applied to all tasks
default_args = {
    "owner": "data_engineering",
    "depends_on_past": False,
    "email_on_failure": False,
    "email_on_retry": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
    "execution_timeout": timedelta(minutes=45),
}

# Base configuration paths
DBT_PROJECT_DIR = "/opt/airflow/dbt_project"
# Profiles can reside in the project root or in standard ~/.dbt
DBT_PROFILES_DIR = os.environ.get("DBT_PROFILES_DIR", DBT_PROJECT_DIR)

# Environment variables injected into dbt execution context
dbt_env = {
    "PATH": os.environ.get("PATH", "/home/airflow/.local/bin:/usr/local/bin:/usr/bin:/bin"),
    "DBT_PROFILES_DIR": DBT_PROFILES_DIR,
    # Database connection parameters forwarded from Airflow container environment
    "DBT_PROD_HOST": os.environ.get("DBT_PROD_HOST", "postgres"),
    "DBT_PROD_PORT": os.environ.get("DBT_PROD_PORT", "5432"),
    "DBT_PROD_DB": os.environ.get("DBT_PROD_DB", "analytics_prod"),
    "DBT_DB_USER": os.environ.get("DBT_DB_USER", "dbt_runner"),
    "DBT_DB_PASSWORD": os.environ.get("DBT_DB_PASSWORD", "dbt_runner_pass"),
    "DBT_PROD_SCHEMA": os.environ.get("DBT_PROD_SCHEMA", "public"),
}

with DAG(
    dag_id="dbt_production_pipeline",
    default_args=default_args,
    description="Automated dbt dependency resolution and production model build",
    schedule_interval="0 3 * * *",  # Daily at 03:00 UTC
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["dbt", "analytics", "production", "bash_operator"],
    doc_md=__doc__,
) as dag:

    # Task 1: Check project directory existence and dbt version
    dbt_precheck = BashOperator(
        task_id="dbt_precheck",
        bash_command=f"""
            echo "=== Validating dbt project path ==="
            if [ ! -d "{DBT_PROJECT_DIR}" ]; then
                echo "CRITICAL ERROR: Directory {DBT_PROJECT_DIR} not found or unmounted!" >&2
                exit 1
            fi
            echo "Project found at {DBT_PROJECT_DIR}. Listing contents:"
            ls -la {DBT_PROJECT_DIR}
            echo "dbt executable version:"
            dbt --version
        """,
        env=dbt_env,
    )

    # Task 2: Install and synchronize dbt packages dependencies (packages.yml)
    dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command=f"""
            set -eo pipefail
            echo "=== Running dbt deps in {DBT_PROJECT_DIR} ==="
            cd {DBT_PROJECT_DIR}
            dbt deps --profiles-dir {DBT_PROFILES_DIR}
        """,
        env=dbt_env,
    )

    # Task 3: Build models, run tests, and execute snapshots against production target
    dbt_build_prod = BashOperator(
        task_id="dbt_build_prod",
        bash_command=f"""
            set -eo pipefail
            echo "=== Running dbt build --target prod in {DBT_PROJECT_DIR} ==="
            cd {DBT_PROJECT_DIR}
            dbt build --profiles-dir {DBT_PROFILES_DIR} --target prod
        """,
        env=dbt_env,
    )

    # Execution flow definition
    dbt_precheck >> dbt_deps >> dbt_build_prod

