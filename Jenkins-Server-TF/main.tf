provider "aws" {
  region = var.aws_region
}

# ──────────────────────────────────────────────
#  Latest Ubuntu 22.04 AMI
# ──────────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ──────────────────────────────────────────────
#  Security Group
# ──────────────────────────────────────────────
resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-cloud-native-sg"
  description = "Allow SSH, Jenkins, SonarQube, and app traffic"

  # SSH
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Jenkins UI
  ingress {
    description = "Jenkins web UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SonarQube
  ingress {
    description = "SonarQube web UI"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "Jenkins-Cloud-Native-SG"
    Project = "cloud-native-eks"
  }
}

# ──────────────────────────────────────────────
#  IAM Role & Instance Profile
# ──────────────────────────────────────────────
resource "aws_iam_role" "jenkins_role" {
  name = "jenkins-cloud-native-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "Jenkins-Cloud-Native-Role"
    Project = "cloud-native-eks"
  }
}

resource "aws_iam_role_policy_attachment" "jenkins_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AWSCloudFormationFullAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
    "arn:aws:iam::aws:policy/AmazonVPCFullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/AmazonRoute53FullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess",
    # Required for Terraform state locking (DynamoDB lock table)
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess",
    # Required for Nimbus operational tasks (verifying ESO secrets, rotation checks)
    "arn:aws:iam::aws:policy/SecretsManagerReadWrite",
  ])

  role       = aws_iam_role.jenkins_role.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "eks_full_access" {
  name = "EKSFullAccess"
  role = aws_iam_role.jenkins_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:*"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "nimbus_infra_access" {
  name = "NimbusInfraAccess"
  role = aws_iam_role.jenkins_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["rds:*", "elasticache:*"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-cloud-native-profile"
  role = aws_iam_role.jenkins_role.name
}

# ──────────────────────────────────────────────
#  EC2 Instance
# ──────────────────────────────────────────────
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.jenkins_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_profile.name
  user_data              = file("tools-install.sh")

  root_block_device {
    volume_size = var.volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name    = "Jenkins-Cloud-Native"
    Project = "cloud-native-eks"
  }
}
