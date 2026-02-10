terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # IMPORTANT: Create the bucket manually first, or use a local backend initially.
  # Then migrate: tofu init -migrate-state
  backend "gcs" {
    # Set via: tofu init -backend-config="bucket=YOUR_BUCKET"
    # Or create a backend.tfvars file (gitignored).
    prefix = "tofu/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# -------------------------------------------------------------------
# Service Account
# -------------------------------------------------------------------

resource "google_service_account" "openclaw" {
  account_id   = var.service_account_id
  display_name = "OpenClaw Gateway Service Account"
}

resource "google_project_iam_member" "openclaw_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.openclaw.email}"
}

resource "google_project_iam_member" "openclaw_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.openclaw.email}"
}

# -------------------------------------------------------------------
# GCS Backup Bucket
# -------------------------------------------------------------------

resource "google_storage_bucket" "backup" {
  name                        = var.backup_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  lifecycle_rule {
    condition {
      age = var.backup_retention_days
    }
    action {
      type = "Delete"
    }
  }

  versioning {
    enabled = true
  }
}

resource "google_storage_bucket_iam_member" "backup_admin" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.openclaw.email}"
}

# -------------------------------------------------------------------
# Compute Instance
# -------------------------------------------------------------------

resource "google_compute_instance" "openclaw_gw" {
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["openclaw"]

  boot_disk {
    initialize_params {
      image = "projects/debian-cloud/global/images/family/debian-12"
      size  = var.disk_size_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    network = var.network
    # No external IP — access via IAP tunnel only
    # Subnetwork inferred automatically for default VPC
  }

  service_account {
    email  = google_service_account.openclaw.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/startup.sh", {
      backup_bucket    = var.backup_bucket_name
      timezone         = var.timezone
      backup_hours     = var.backup_cron_interval_hours
      secrets_prefix   = var.secrets_prefix
      backup_retention = var.backup_retention_days
    })
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  labels = {
    app = "openclaw"
  }

  lifecycle {
    ignore_changes = [
      metadata["ssh-keys"],
    ]
  }
}

# -------------------------------------------------------------------
# Secret Manager — API + IAM
# -------------------------------------------------------------------

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_iam_member" "openclaw_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.openclaw.email}"
}

# -------------------------------------------------------------------
# Cloud NAT — Required for VMs without external IP to reach internet
# (apt-get, docker pull, gcloud storage, etc.)
# -------------------------------------------------------------------

resource "google_compute_router" "openclaw" {
  name    = "openclaw-router"
  region  = var.region
  network = var.network
}

resource "google_compute_router_nat" "openclaw" {
  name                               = "openclaw-nat"
  router                             = google_compute_router.openclaw.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  min_ports_per_vm                   = 64
}

# -------------------------------------------------------------------
# IAP Firewall Rule (SSH access via IAP tunnel)
# -------------------------------------------------------------------

resource "google_compute_firewall" "iap_ssh" {
  name    = "allow-iap-ssh-openclaw"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP's IP range
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["openclaw"]
}
