FROM apache/airflow:2.8.1-python3.10

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
USER airflow

# Step A: providers, constrained against the same Airflow release
RUN pip install --no-cache-dir \
    apache-airflow-providers-amazon \
    apache-airflow-providers-snowflake \
    pandas \
    plotly \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.8.1/constraints-3.10.txt"

# Step B: dbt, unconstrained — kept in a separate layer so its own
# dependency resolution never has to satisfy Airflow's constraint file
RUN pip install --no-cache-dir dbt-core dbt-snowflake

COPY entrypoint.sh /entrypoint.sh
USER root
RUN chmod +x /entrypoint.sh
USER airflow

ENTRYPOINT ["/entrypoint.sh"]
