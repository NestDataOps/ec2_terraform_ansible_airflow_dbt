FROM apache/airflow:2.8.1-python3.10

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

COPY init.sh /init.sh
USER root
RUN chmod +x /init.sh
USER airflow
