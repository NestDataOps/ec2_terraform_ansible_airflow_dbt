terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket = "github-actions-terraform-822872386722-us-east-1-an"
    key    = "k3_ec2_terraform_state/ec2.tfstate"
    region = "us-east-1"
  }
}

variable "key_name" {
  description = "Name of the existing EC2 Key Pair in AWS"
  type        = string
  # You can set a default here, or pass it via TF_VAR_key_name in GitHub Actions
  default = "damsteele66-us-east-1"
}

variable "private_key" { type = string }

# --- Snowflake connection details (for the Airflow 'snowflake_default' connection) ---
variable "snowflake_account" {
  description = "Snowflake account identifier"
  type        = string
  default     = "IQFGCYU-UA55363"
}

variable "snowflake_warehouse" {
  description = "Snowflake warehouse"
  type        = string
  default     = "japan_visa_wh"
}

variable "snowflake_database" {
  description = "Snowflake database"
  type        = string
  default     = "japan_visa_db"
}

variable "snowflake_role" {
  description = "Snowflake role"
  type        = string
  default     = "accountadmin"
}

variable "snowflake_login" {
  description = "Snowflake login/username"
  type        = string
  default     = "NESTDATAOPS"
}

variable "snowflake_password" {
  description = "Snowflake password. Pass via TF_VAR_snowflake_password in GitHub Actions (sourced from a repo secret)."
  type        = string
  sensitive   = true
}

# --- AWS credentials for the Airflow 'aws_default' connection ---
# NOTE: these are separate from the AWS credentials GitHub Actions uses to
# run `terraform apply` itself (configure-aws-credentials step). These are
# the credentials DAGs will use at runtime (e.g. via S3Hook, boto3, etc).
variable "airflow_aws_access_key_id" {
  description = "AWS access key ID for Airflow's aws_default connection. Pass via TF_VAR_airflow_aws_access_key_id."
  type        = string
  sensitive   = true
}

variable "airflow_aws_secret_access_key" {
  description = "AWS secret access key for Airflow's aws_default connection. Pass via TF_VAR_airflow_aws_secret_access_key."
  type        = string
  sensitive   = true
}

data "aws_vpc" "default" {
  default = true
}

#variable "vpc_id" {
#  description = "The ID of the VPC where the instance will be deployed"
#  type        = string
# Optional: If deploying to the default VPC, you can omit this variable 
# and the vpc_id argument in the security group.
#}

# 1. Security Group Configuration
resource "aws_security_group" "airflow_sg" {
  name        = "airflow-k3s-sg"
  description = "Security group for K3s and Airflow"
  vpc_id      = data.aws_vpc.default.id

  # SSH - Required for GitHub Actions to fetch the kubeconfig
  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Note: In production, restrict to specific IPs
  }

  # Kubernetes API - Required for the Terraform Helm provider
  ingress {
    description = "Allow K3s API access"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Airflow Web UI - Assuming NodePort or default port forwarding
  ingress {
    description = "Allow Airflow Web UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound Internet Access - Required to download K3s, Airflow images, and Python packages
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. EC2 Instance Configuration
resource "aws_instance" "airflow_server" {
  # Ubuntu 22.04 LTS (Make sure to update this AMI ID for your specific AWS region)
  ami           = "ami-0c7217cdde317cfec"
  instance_type = "t3a.small"

  # Reference the existing Key Pair here
  key_name = var.key_name

  # Attach the security group defined above
  vpc_security_group_ids = [aws_security_group.airflow_sg.id]
  user_data = <<-EOF
#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -ex

echo "=== user-data script started at $(date -u) ==="

# Update packages and install dependencies (git added for repo clone)
apt-get update -y
apt-get install -y python3-pip python3-venv sqlite3 git

# Create dedicated airflow user and directory
useradd -m -s /bin/bash airflow || true
mkdir -p /opt/airflow
chown -R airflow:airflow /opt/airflow

# Clone the DAGs/dbt repo and symlink its dags and japan_visa_dbt
# directories into the locations Airflow/dbt expect
rm -rf /opt/airflow/repo
git clone https://github.com/NestDataOps/airflow-dbt-snowflake-japan-visa.git /opt/airflow/repo
chown -R airflow:airflow /opt/airflow/repo

rm -rf /opt/airflow/dags /opt/airflow/japan_visa_dbt
ln -s /opt/airflow/repo/dags /opt/airflow/dags
ln -s /opt/airflow/repo/japan_visa_dbt /opt/airflow/japan_visa_dbt
chown -h airflow:airflow /opt/airflow/dags /opt/airflow/japan_visa_dbt

sudo -u airflow git config --global --add safe.directory /opt/airflow/repo

# Set up Python venv and install Airflow
sudo -u airflow bash -c '
  cd /opt/airflow
  python3 -m venv airflow_env
  source airflow_env/bin/activate

  # Install Airflow using official constraint files
  AIRFLOW_VERSION=2.8.1
  PYTHON_VERSION=$(python3 --version | cut -d " " -f 2 | cut -d "." -f 1-2)
  CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-$${AIRFLOW_VERSION}/constraints-$${PYTHON_VERSION}.txt"

  # Step A: Airflow + providers, constrained
  pip install "apache-airflow==$${AIRFLOW_VERSION}" \
    apache-airflow-providers-amazon \
    apache-airflow-providers-snowflake \
    pandas \
    plotly \
    --constraint "$${CONSTRAINT_URL}"

  # Step B: dbt, unconstrained — let it pick its own compatible deps
  pip install dbt-core dbt-snowflake

  # Initialize DB and create admin user (examples disabled)
  export AIRFLOW_HOME=/opt/airflow
  export AIRFLOW__CORE__LOAD_EXAMPLES=False
  airflow db init
  airflow users create \
      --username admin \
      --firstname Admin \
      --lastname User \
      --role Admin \
      --email admin@example.com \
      --password 77jump88

  # Configure Airflow connections for Snowflake and AWS.
  # Secrets are base64-passed from Terraform variables and decoded here so
  # arbitrary characters in the password/keys never have to be shell-quoted.
  SNOWFLAKE_PASSWORD=$(echo "${base64encode(var.snowflake_password)}" | base64 -d)
  AWS_ACCESS_KEY_ID=$(echo "${base64encode(var.airflow_aws_access_key_id)}" | base64 -d)
  AWS_SECRET_ACCESS_KEY=$(echo "${base64encode(var.airflow_aws_secret_access_key)}" | base64 -d)
  SNOWFLAKE_EXTRA=$(echo "${base64encode(jsonencode({
  account   = var.snowflake_account
  warehouse = var.snowflake_warehouse
  database  = var.snowflake_database
  role      = var.snowflake_role
}))}" | base64 -d)

  airflow connections delete "snowflake_default" 2>/dev/null || true
  airflow connections add "snowflake_default" \
    --conn-type "snowflake" \
    --conn-login "${var.snowflake_login}" \
    --conn-password "$SNOWFLAKE_PASSWORD" \
    --conn-extra "$SNOWFLAKE_EXTRA"

  airflow connections delete "aws_default" 2>/dev/null || true
  airflow connections add "aws_default" \
    --conn-type "aws" \
    --conn-login "$AWS_ACCESS_KEY_ID" \
    --conn-password "$AWS_SECRET_ACCESS_KEY" \
    --conn-extra "{\"region_name\": \"us-east-1\"}"
'

# Create systemd service for Standalone Airflow (Webserver + Scheduler)
cat << 'SERVICE' > /etc/systemd/system/airflow.service
[Unit]
Description=Airflow Standalone Daemon
After=network.target

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
Environment="AIRFLOW__CORE__LOAD_EXAMPLES=False"
Environment="PATH=/opt/airflow/airflow_env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/opt/airflow/airflow_env/bin/airflow standalone
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

# Start and enable service
systemctl daemon-reload
systemctl enable airflow
systemctl start airflow

echo "=== user-data script completed successfully at $(date -u) ==="
  EOF

tags = {
  Name = "Airflow-K3s-Server"
}
}

