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
              set -e

              # 1. Install System Dependencies
              apt-get update -y
              apt-get install -y python3-pip python3-venv sqlite3 git

              # 2. Setup Dedicated Airflow User
              useradd -m -s /bin/bash airflow || true
              mkdir -p /opt/airflow
              chown -R airflow:airflow /opt/airflow

              # 3. Clone Repository & Symlink Directories
              rm -rf /opt/airflow/repo
              git clone https://github.com/NestDataOps/airflow-dbt-snowflake-japan-visa.git /opt/airflow/repo
              chown -R airflow:airflow /opt/airflow/repo

              # Remove default/existing dags if present and build symlinks
              rm -rf /opt/airflow/dags /opt/airflow/japan_visa_dbt
              ln -s /opt/airflow/repo/dags /opt/airflow/dags
              ln -s /opt/airflow/repo/japan_visa_dbt /opt/airflow/japan_visa_dbt
              chown -h airflow:airflow /opt/airflow/dags /opt/airflow/japan_visa_dbt

              # Configure Git safe directory for airflow user
              sudo -u airflow git config --global --add safe.directory /opt/airflow/repo

              # 4. Create Virtual Environment & Install Packages as Airflow User
              sudo -u airflow bash << 'BUILD_ENV'
              cd /opt/airflow
              python3 -m venv airflow_env
              source airflow_env/bin/activate

              pip install --upgrade pip setuptools wheel

              AIRFLOW_VERSION=2.8.1
              PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
              CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-$${AIRFLOW_VERSION}/constraints-$${PYTHON_VERSION}.txt"

              # Step A: Install Airflow and Airflow Providers with constraints
              pip install "apache-airflow==$${AIRFLOW_VERSION}" \
                apache-airflow-providers-amazon \
                apache-airflow-providers-snowflake \
                pandas \
                plotly \
                --constraint "$${CONSTRAINT_URL}"

              # Step B: Install dbt separately without constraints to resolve conflicts
              pip install dbt-core dbt-snowflake

              # Step C: Initialize Airflow Database and Create Admin User
              export AIRFLOW_HOME=/opt/airflow
              export AIRFLOW__CORE__LOAD_EXAMPLES=False

              airflow db init
              airflow users create \
                --username admin \
                --firstname Admin \
                --lastname User \
                --role Admin \
                --email admin@example.com \
                --password admin
BUILD_ENV

              # 5. Create System-Wide Symlink for dbt CLI
              ln -sf /opt/airflow/airflow_env/bin/dbt /usr/local/bin/dbt

              # 6. Create Systemd Service File
              cat << 'SERVICE' > /etc/systemd/system/airflow.service
              [Unit]
              Description=Airflow Standalone Daemon
              After=network.target

              [Service]
              User=airflow
              Group=airflow
              Environment="AIRFLOW_HOME=/opt/airflow"
              Environment="PATH=/opt/airflow/airflow_env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
              ExecStart=/opt/airflow/airflow_env/bin/airflow standalone
              Restart=always
              RestartSec=5s

              [Install]
              WantedBy=multi-user.target
              SERVICE

              # 7. Reload Systemd, Enable Service, and Setup Auto-Pull Cron Job
              systemctl daemon-reload
              systemctl enable airflow
              systemctl start airflow

              (crontab -u airflow -l 2>/dev/null; echo "*/5 * * * * git -C /opt/airflow/repo pull > /dev/null 2>&1") | crontab -u airflow -
              EOF


  tags = {
    Name = "Airflow-K3s-Server"
  }
}

