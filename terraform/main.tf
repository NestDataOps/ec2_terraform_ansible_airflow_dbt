# 4
terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket = "github-actions-terraform-822872386722-us-east-1-an"
    key    = "k3_ec2_terraform_state/ec2.tfstate"
    region = "us-east-1"
  }
}

# S3 Bucket for Processed Data
resource "aws_s3_bucket" "processed_data" {
  bucket = "eventdriven-pipeline-processed"
}

# Enable EventBridge to broadcast S3 object events
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket      = aws_s3_bucket.processed_data.id
  eventbridge = true
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

  # No provisioning here — Ansible handles setup after the instance boots.
  # user_data is left minimal so cloud-init finishes fast and SSH is
  # available almost immediately for Ansible to connect.
  user_data = <<-EOF
#!/bin/bash
exec > /var/log/user-data.log 2>&1
set -ex
echo "=== cloud-init boot complete, ready for Ansible at $(date -u) ==="
EOF

  tags = {
    Name = "Airflow-K3s-Server"
  }
}

output "public_ip" {
  description = "Public IP of the Airflow EC2 instance"
  value       = aws_instance.airflow_server.public_ip
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "lambda_function.py"
  output_path = "lambda_function.zip"
}

resource "aws_iam_role" "lambda_exec" {
  name = "airflow_trigger_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_exec.name
}

resource "aws_lambda_function" "airflow_trigger" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "trigger-airflow-dag"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.10"

  environment {
    variables = {
      # Dynamically references the EC2 public IP and the Airflow Web UI port
      AIRFLOW_URL  = "http://${aws_instance.airflow_server.public_ip}:8080"
      DAG_ID       = "s3_to_snowflake_dbt"
      AIRFLOW_USER = "admin"
      AIRFLOW_PASS = "admin"
    }
  }
}

resource "aws_cloudwatch_event_rule" "s3_upload" {
  name        = "capture-s3-parquet-upload"
  description = "Trigger on Object Created in processed bucket"
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.processed_data.id] }
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.s3_upload.name
  target_id = "TriggerAirflowLambda"
  arn       = aws_lambda_function.airflow_trigger.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.airflow_trigger.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_upload.arn
}
