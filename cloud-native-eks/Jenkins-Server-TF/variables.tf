variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type for Jenkins server (m7i-flex.large = 8GB RAM for Jenkins + SonarQube + Docker)"
  type        = string
  default     = "m7i-flex.large"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = "test"
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}
