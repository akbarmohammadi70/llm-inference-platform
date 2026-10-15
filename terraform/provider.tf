terraform {
  required_providers {
    arvancloud = {
      source = "terraform.arvancloud.ir/arvancloud/arvancloud"
    }
    null = {
      source = "hashicorp/null"
    }
    time = {
      source = "hashicorp/time"
    }
  }
}
provider "arvancloud" {
  api_key = var.api_key
}
