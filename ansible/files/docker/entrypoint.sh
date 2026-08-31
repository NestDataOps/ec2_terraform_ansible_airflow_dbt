#!/bin/bash
set -e

# Only run one-time setup if the metadata DB doesn't exist yet — this makes
# container restarts (and `docker compose up` re-runs) idempotent.
if [ ! -f "${AIRFLOW_HOME}/airflow.db" ]; then
  echo "=== First run: initializing Airflow DB and connections ==="
  airflow db init

  airflow users create \
    --username admin --firstname Admin --lastname User \
    --role Admin --email admin@example.com --password admin

  airflow connections delete snowflake_default 2>/dev/null || true
  airflow connections add snowflake_default \
    --conn-type snowflake \
    --conn-login "${SNOWFLAKE_USER}" \
    --conn-password "${DBT_SNOWFLAKE_PASSWORD}" \
    --conn-extra "{\"account\": \"${SNOWFLAKE_ACCOUNT}\", \"warehouse\": \"${SNOWFLAKE_WAREHOUSE}\", \"database\": \"${SNOWFLAKE_DATABASE}\", \"role\": \"${SNOWFLAKE_ROLE}\"}"

  airflow connections delete aws_default 2>/dev/null || true
  airflow connections add aws_default \
    --conn-type aws \
    --conn-login "${AIRFLOW_AWS_ACCESS_KEY_ID}" \
    --conn-password "${AIRFLOW_AWS_SECRET_ACCESS_KEY}" \
    --conn-extra '{"region_name": "us-east-1"}'
else
  echo "=== Airflow DB already exists, skipping init ==="
fi

# No triggerer — it's only needed for deferrable operators, which this
# pipeline doesn't use, and it's a full extra process on a memory-constrained
# instance. Scheduler runs in the background, webserver stays in the
# foreground so the container's main process is the one Docker tracks.
airflow scheduler &
exec airflow webserver
