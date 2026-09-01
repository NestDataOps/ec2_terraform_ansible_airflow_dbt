#!/bin/bash
set -e

echo "=== Running Airflow DB migration ==="
airflow db migrate

echo "=== Ensuring admin user exists ==="
airflow users create \
  --username admin --firstname Admin --lastname User \
  --role Admin --email admin@example.com --password admin \
  || echo "Admin user already exists, continuing."

echo "=== Configuring connections ==="
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

echo "=== Init complete ==="
