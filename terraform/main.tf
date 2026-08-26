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
  user_data              = <<-EOF
              #!/bin/bash
              # Update packages and install Python dependencies
              apt-get update -y
              apt-get install -y python3-pip python3-venv sqlite3

              # Create dedicated airflow user and directory
              useradd -m -s /bin/bash airflow
              mkdir -p /opt/airflow
              chown -R airflow:airflow /opt/airflow

              # Set up Python venv and install Airflow
              sudo -u airflow bash -c '
                cd /opt/airflow
                python3 -m venv airflow_env
                source airflow_env/bin/activate
                
                # Install Airflow using official constraint files
                AIRFLOW_VERSION=2.8.1
                PYTHON_VERSION=$(python3 --version | cut -d " " -f 2 | cut -d "." -f 1-2)
                CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-$${AIRFLOW_VERSION}/constraints-$${PYTHON_VERSION}.txt"
                pip install "apache-airflow==$${AIRFLOW_VERSION}" --constraint "$${CONSTRAINT_URL}"
                
                # Initialize DB and create admin user
                export AIRFLOW_HOME=/opt/airflow
                airflow db init
                airflow users create \
                    --username admin \
                    --firstname Admin \
                    --lastname User \
                    --role Admin \
                    --email admin@example.com \
                    --password admin
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
              EOF

  tags = {
    Name = "Airflow-K3s-Server"
  }
}

