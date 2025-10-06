terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = "velvety-pagoda-474218-r6"
  region  = "us-west1"
}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.bidflow_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.bidflow_cluster.master_auth[0].cluster_ca_certificate)
}

data "google_client_config" "default" {}

resource "google_container_cluster" "bidflow_cluster" {
  name     = "bidflow-autopilot"
  location = "us-west1-a"

  deletion_protection = false

  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    machine_type = "e2-micro"
    disk_type    = "pd-standard"
    disk_size_gb = 20
  }

  release_channel {
    channel = "REGULAR"
  }
}

resource "kubernetes_namespace" "bidflow_ns" {
  metadata {
    name = "bidflow"
  }

  depends_on = [google_container_cluster.bidflow_cluster]
}

resource "kubernetes_persistent_volume_claim" "redis_pvc" {
  metadata {
    name      = "redis-pvc"
    namespace = kubernetes_namespace.bidflow_ns.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    storage_class_name = "standard" 
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace.bidflow_ns]
}