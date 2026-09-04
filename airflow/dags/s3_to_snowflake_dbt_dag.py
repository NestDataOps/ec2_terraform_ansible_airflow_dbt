"""
Event-driven-ish, Airflow-centric pipeline.

Lambda (triggered by EventBridge on S3 upload) has already cleaned and
flattened the raw JSON into Parquet in the processed/ bucket by the time
this DAG's sensor fires. From here, Airflow owns the rest of the lineage:

  1. Sense the new Parquet file landing in the processed bucket
     (deferrable sensor -- doesn't occupy a worker slot while polling).
  2. COPY INTO the Snowflake raw table from the external stage.
  3. Run dbt (staging -> marts) to produce the analytics-ready models.

Schedule is None: this DAG is meant to be triggered externally, e.g. by
an S3 "Object Created" -> EventBridge -> Lambda that calls the Airflow
REST API, or simply by running on a short schedule and relying on the
sensor to no-op when nothing new has landed. See README for both options.
"""

from datetime import datetime, timedelta

from airflow.decorators import dag, task
from airflow.providers.amazon.aws.sensors.s3 import S3KeySensor
from airflow.providers.snowflake.operators.snowflake import SnowflakeOperator
from airflow.operators.bash import BashOperator

PROCESSED_BUCKET = "eventdriven-pipeline-processed"
PROCESSED_PREFIX = "processed/"
SNOWFLAKE_CONN_ID = "snowflake_default"
DBT_PROJECT_DIR = "/opt/airflow/dbt"
DBT_PROFILES_DIR = "/opt/airflow/dbt"

default_args = {
    "owner": "data-eng",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
}


@dag(
    dag_id="s3_to_snowflake_dbt",
    description="Senses processed Parquet -> loads Snowflake raw -> runs dbt",
    schedule=None,  # triggered externally; see README
    start_date=datetime(2026, 1, 1),
    catchup=False,
    default_args=default_args,
    tags=["event-driven", "snowflake", "dbt"],
    params={"s3_key": ""},  # passed in by the trigger (specific file), optional
)
def s3_to_snowflake_dbt():

    # Deferrable sensor: releases the worker slot while waiting, resumes
    # when the triggerer detects the object. Falls back to wildcard match
    # on the whole prefix if no specific key is passed via params.
    wait_for_parquet = S3KeySensor(
        task_id="wait_for_processed_parquet",
        bucket_name=PROCESSED_BUCKET,
        bucket_key="{{ params.s3_key or (params.s3_key == '' and 'processed/*.parquet') }}",
        wildcard_match=True,
        aws_conn_id="aws_default",
        deferrable=True,
        timeout=60 * 30,
        poke_interval=30,
    )

    # COPY INTO the raw landing table from the external stage. Uses
    # FORCE = FALSE so re-running the DAG on the same file is idempotent --
    # Snowflake tracks load history per stage/table pair for 64 days.
    load_to_raw = SnowflakeOperator(
        task_id="copy_into_raw_events",
        snowflake_conn_id=SNOWFLAKE_CONN_ID,
        sql="""
            COPY INTO EVENTDRIVEN_PIPELINE_DB.RAW.RAW_EVENTS
            FROM (
                SELECT
                    $1:event_id::STRING,
                    $1:event_type::STRING,
                    $1,
                    $1:source_file_name::STRING,
                    CURRENT_TIMESTAMP()
                FROM @EVENTDRIVEN_PIPELINE_DB.RAW.PROCESSED_STAGE
            )
            PATTERN = '.*\\.parquet'
            FILE_FORMAT = (FORMAT_NAME = EVENTDRIVEN_PIPELINE_DB.RAW.PARQUET_FORMAT)
            FORCE = FALSE;
        """,
    )

    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt run --profiles-dir {DBT_PROFILES_DIR} --select staging marts"
        ),
    )

    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=(
            f"cd {DBT_PROJECT_DIR} && "
            f"dbt test --profiles-dir {DBT_PROFILES_DIR}"
        ),
    )

    wait_for_parquet >> load_to_raw >> dbt_run >> dbt_test


s3_to_snowflake_dbt()
