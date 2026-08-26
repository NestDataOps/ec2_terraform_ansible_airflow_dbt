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
              # Install K3s
              curl -sfL https://get.k3s.io | sh -
              
              # Set up kubeconfig for the 'ubuntu' user
              mkdir -p /home/ubuntu/.kube
              cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
              chown -R ubuntu:ubuntu /home/ubuntu/.kube
              
              # Replace 127.0.0.1 with the instance's public IP so remote connections work
              PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
              sed -i "s/127.0.0.1/$PUBLIC_IP/g" /home/ubuntu/.kube/config
              EOF

  tags = {
    Name = "Airflow-K3s-Server"
  }
}



# Configure the Helm provider
provider "helm" {
  kubernetes {
    # Replace with the public IP of your EC2 instance once provisioned
    host                   = "https://${aws_instance.airflow_server.public_ip}:6443"
    
    # Enable insecure or provide ca_certificate / token if preferred
    insecure               = true 
  }
}

# Deploy Airflow via official Helm Chart
resource "helm_release" "airflow" {
  name             = "airflow"
  repository       = "https://airflow.apache.org"
  chart            = "airflow"
  namespace        = "airflow"
  create_namespace = true

  # Override Airflow settings (e.g., executor, resource limits)
  set {
    name  = "executor"
    value = "LocalExecutor"
  }

  depends_on = [aws_instance.airflow_server]
}
