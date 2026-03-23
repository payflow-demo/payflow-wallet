terraform {
  backend "s3" {
    bucket         = "payflow-tfstate-334091769766"
    key            = "aws/finops/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "payflow-tfstate-lock"
    encrypt        = true
  }
}
