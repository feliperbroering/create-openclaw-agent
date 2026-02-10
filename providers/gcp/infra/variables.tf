# -------------------------------------------------------------------
# Required Variables (must be set in terraform.tfvars)
# -------------------------------------------------------------------

variable "project_id" {
  description = "GCP project ID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 6-30 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "backup_bucket_name" {
  description = "Globally unique GCS bucket name for backups and Tofu state"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.backup_bucket_name))
    error_message = "backup_bucket_name must be 3-63 chars: lowercase letters, digits, hyphens, underscores, dots."
  }
}

# -------------------------------------------------------------------
# Optional Variables (sensible defaults)
# -------------------------------------------------------------------

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.region))
    error_message = "region must contain only lowercase letters, digits, and hyphens."
  }
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.zone))
    error_message = "zone must contain only lowercase letters, digits, and hyphens."
  }
}

variable "machine_type" {
  description = "GCE machine type (e2-medium recommended with browser support)"
  type        = string
  default     = "e2-medium"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.machine_type))
    error_message = "machine_type must contain only lowercase letters, digits, and hyphens."
  }
}

variable "disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20

  validation {
    condition     = var.disk_size_gb >= 10 && var.disk_size_gb <= 500
    error_message = "disk_size_gb must be between 10 and 500. Minimum 10 GB needed for OS + Docker images + data."
  }
}

variable "timezone" {
  description = "Timezone for the VM (IANA format)"
  type        = string
  default     = "UTC"

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_+-]+$", var.timezone))
    error_message = "timezone must be a valid IANA timezone (letters, digits, /, _, +, -)."
  }
}

variable "vm_name" {
  description = "Name of the GCE instance"
  type        = string
  default     = "openclaw-gw"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.vm_name))
    error_message = "vm_name must start with a letter and contain only lowercase letters, digits, and hyphens (max 63 chars)."
  }
}

variable "service_account_id" {
  description = "Service account ID (without @project.iam.gserviceaccount.com)"
  type        = string
  default     = "openclaw-sa"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.service_account_id))
    error_message = "service_account_id must be 6-30 lowercase letters, digits, or hyphens."
  }
}

variable "network" {
  description = "VPC network name"
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.network))
    error_message = "network must start with a letter and contain only lowercase letters, digits, and hyphens."
  }
}

variable "backup_retention_days" {
  description = "Days to retain backups in GCS before auto-deletion"
  type        = number
  default     = 90

  validation {
    condition     = var.backup_retention_days >= 1 && var.backup_retention_days <= 365
    error_message = "backup_retention_days must be between 1 and 365."
  }
}

variable "backup_cron_interval_hours" {
  description = "Hours between automatic backups"
  type        = number
  default     = 6

  validation {
    condition     = var.backup_cron_interval_hours >= 1 && var.backup_cron_interval_hours <= 24
    error_message = "backup_cron_interval_hours must be between 1 and 24."
  }
}

variable "secrets_prefix" {
  description = "Prefix for Secret Manager secret names"
  type        = string
  default     = "openclaw"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_-]{0,254}$", var.secrets_prefix))
    error_message = "secrets_prefix must start with a letter and contain only alphanumeric characters, hyphens, and underscores."
  }
}
