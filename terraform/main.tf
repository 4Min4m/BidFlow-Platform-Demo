terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "velvety-pagoda-474218-r6"
  region  = "us-central1"
}

# Create GKE Autopilot Cluster
resource "google_container_cluster" "bidflow_cluster" {
  name     = "bidflow-autopilot"
  location = "us-central1"

  enable_autopilot = true

  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = false
}

# Output instructions
output "cluster_name" {
  value = google_container_cluster.bidflow_cluster.name
}

output "setup_commands" {
  value = <<-EOT
    Run these command after cluster is created:
    
    1. Configure kubectl:
       gcloud container clusters get-credentials bidflow-autopilot --region=us-central1 --project=velvety-pagoda-474218-r6
  EOT
}