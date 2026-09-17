terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------
locals {
  required_apis = [
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_apis)
  project  = var.project_id
  service  = each.value

  disable_dependent_services = false
  disable_on_destroy         = false
}

# ---------------------------------------------------------------------------
# GKE Autopilot Cluster
# ---------------------------------------------------------------------------
resource "google_container_cluster" "bidflow_cluster" {
  name     = "bidflow-autopilot"
  location = var.region

  enable_autopilot = true

  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = false

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Artifact Registry
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "bidflow" {
  location      = var.region
  repository_id = "bidflow"
  description   = "BidFlow polyglot service images (go-bidder, ruby-bidder)"
  format        = "DOCKER"

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# GCS bucket for Redis RDB backups (target of the CronJob's gsutil cp)
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "backups" {
  name                        = var.backup_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true # portfolio project — fine to allow teardown

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Backup service account
# ---------------------------------------------------------------------------
resource "google_service_account" "backup" {
  account_id   = "bidflow-backup"
  display_name = "BidFlow Redis backup (Workload Identity)"
}

resource "google_storage_bucket_iam_member" "backup_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_service_account_iam_member" "backup_workload_identity" {
  service_account_id = google_service_account.backup.name
  role                = "roles/iam.workloadIdentityUser"
  # Binds the KSA "bidflow-backup" in the "bidflow" namespace specifically —
  # any other KSA in the project cannot impersonate this GSA.
  member = "serviceAccount:${var.project_id}.svc.id.goog[bidflow/bidflow-backup]"
}

# ---------------------------------------------------------------------------
# Workload Identity Federation for GitHub Actions — the CI pipeline
# authenticates to GCP with a short-lived federated token instead of a
# downloaded JSON service-account key.
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions"
  description               = "Federated identities for BidFlow's GitHub Actions CI/CD"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id         = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only THIS repo's tokens are accepted
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions" {
  account_id   = "bidflow-github-actions"
  display_name = "BidFlow CI/CD (GitHub Actions, Workload Identity Federation)"
}

resource "google_service_account_iam_member" "github_actions_wif_binding" {
  service_account_id = google_service_account.github_actions.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_project_iam_member" "github_actions_artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_actions_gke_deployer" {
  project = var.project_id
  role    = "roles/container.developer" # get-credentials + kubectl/helm apply, not cluster-admin
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "cluster_name" {
  value = google_container_cluster.bidflow_cluster.name
}

output "artifact_registry_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.bidflow.repository_id}"
  description = "Set as `imageRegistry` in helm/values.yaml"
}

output "backup_bucket" {
  value = google_storage_bucket.backups.name
}

output "backup_service_account_email" {
  value = google_service_account.backup.email
}

output "github_actions_service_account_email" {
  value = google_service_account.github_actions.email
}

output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Full resource name — goes into the GitHub Actions workflow's `workload_identity_provider` input"
}

output "setup_commands" {
  value = <<-EOT
    Run these once, after `terraform apply`:

    1. Configure kubectl:
       gcloud container clusters get-credentials ${google_container_cluster.bidflow_cluster.name} \
         --region=${var.region} --project=${var.project_id}

    2. Set these as GitHub Actions repo variables (Settings > Secrets and
       variables > Actions > Variables) — no secrets needed, WIF is keyless:
       WIF_PROVIDER = ${google_iam_workload_identity_pool_provider.github.name}
       WIF_SERVICE_ACCOUNT = ${google_service_account.github_actions.email}
       ARTIFACT_REGISTRY = ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.bidflow.repository_id}
       GKE_REGION = ${var.region}

    3. Put the same three values into helm/values.yaml (imageRegistry) and
       helm/values.yaml (backup.gcpServiceAccountEmail = ${google_service_account.backup.email},
       backup.gcs.bucket = ${google_storage_bucket.backups.name}).
  EOT
}