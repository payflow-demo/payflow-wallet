locals {
  env = terraform.workspace

  common_tags = {
    project       = "payflow"
    environment   = local.env
    team          = "engineering"
    owner         = "engineering"
    "cost-center" = "ENG-001"
    "managed-by"  = "terraform"
    module        = "hub-vpc"
  }
}

