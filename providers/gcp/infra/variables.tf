# -------------------------------------------------------------------
# Required Variables (must be set in terraform.tfvars)
# -------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "backup_bucket_name" {
  description = "Globally unique GCS bucket name for backups and Tofu state"
  type        = string
}

# -------------------------------------------------------------------
# Optional Variables (sensible defaults)
# -------------------------------------------------------------------

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "machine_type" {
  description = "GCE machine type (e2-medium recommended with browser support)"
  type        = string
  default     = "e2-medium"
}

variable "disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "timezone" {
  description = "Timezone for the VM (IANA format)"
  type        = string
  default     = "UTC"
}

variable "vm_name" {
  description = "Name of the GCE instance"
  type        = string
  default     = "openclaw-gw"
}

variable "service_account_id" {
  description = "Service account ID (without @project.iam.gserviceaccount.com)"
  type        = string
  default     = "openclaw-sa"
}

variable "network" {
  description = "VPC network name"
  type        = string
  default     = "default"
}

variable "backup_retention_days" {
  description = "Days to retain backups in GCS before auto-deletion"
  type        = number
  default     = 90
}

variable "backup_cron_interval_hours" {
  description = "Hours between automatic backups"
  type        = number
  default     = 6
}

variable "secrets_prefix" {
  description = "Prefix for Secret Manager secret names"
  type        = string
  default     = "openclaw"
}
