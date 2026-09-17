variable "project_id" {
  description = "GCP project ID BidFlow deploys into."
  type        = string
}

variable "region" {
  description = "GCP region for the cluster, registry, and bucket."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = <<-EOT
    "<github-org-or-user>/<repo>" — scopes the Workload Identity Federation
    provider so ONLY GitHub Actions runs from this exact repo can impersonate
    the CI service account.
  EOT
  type = string
}

variable "backup_bucket_name" {
  description = "Globally-unique GCS bucket name for Redis RDB backups."
  type        = string
}