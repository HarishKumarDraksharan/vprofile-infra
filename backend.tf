terraform {
  backend "s3" {
    bucket = "gitiops-terraformcode928"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}