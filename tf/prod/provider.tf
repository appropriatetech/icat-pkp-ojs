terraform {
  required_version = ">= 1.0"
  
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
  
  backend "gcs" {
    bucket = "inat-iac"
    prefix = "tf/state/icat-pkp-ojs/prod"
  }
}

provider "google" {
  project = local.project_id
  region  = local.region
}
