# ==============================================================================
# Apache Airflow 2.9.2 Custom Image with dbt-postgres & Git
# ==============================================================================
FROM apache/airflow:2.9.2-python3.11

LABEL maintainer="Data Engineering Team"
LABEL description="Airflow 2.9.2 with Git and dbt-postgres"

# Switch to root to install OS-level packages (Git, build tools)
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        curl \
        libpq-dev \
        build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Switch back to airflow user for pip installations and security
USER airflow

# Copy requirements file
COPY --chown=airflow:root requirements.txt /opt/airflow/requirements.txt

# Install python packages
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /opt/airflow/requirements.txt

