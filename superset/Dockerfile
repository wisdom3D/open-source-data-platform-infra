# ==============================================================================
# Apache Superset 4.0.1 Custom Image with PostgreSQL Driver
# ==============================================================================
FROM apache/superset:4.0.1

LABEL maintainer="Data Engineering Team"
LABEL description="Superset 4.0.1 with PostgreSQL driver (psycopg2-binary)"

# Switch to root to install driver and dependencies
USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        libpq-dev \
        build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install PostgreSQL adapter for Superset metadata & data source connection
RUN pip install --no-cache-dir psycopg2-binary>=2.9.9

# Switch back to superset user
USER superset

