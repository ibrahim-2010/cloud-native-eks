terraform {
  backend "s3" {
    bucket         = "ibrahim-cloud-native-tf-state"
    key            = "jenkins/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ibrahim-cloud-native-tf-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.9.0"
}
