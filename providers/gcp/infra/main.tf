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
  description  = "Service account for the OpenClaw gateway VM — accesses Secret Manager, GCS backups, and logging"
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

  labels = {
    app = "openclaw"
  }

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
  description  = "OpenClaw AI agent gateway — runs Docker containers for gateway, Qdrant, and Chrome"

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
    email = google_service_account.openclaw.email
    scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/devstorage.read_write",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/compute.readonly",
    ]
  }

  metadata = {
    enable-oslogin = "TRUE"
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
# Audit Logging — Track access to backup bucket
# -------------------------------------------------------------------

resource "google_project_iam_audit_config" "storage_audit" {
  project = var.project_id
  service = "storage.googleapis.com"

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# -------------------------------------------------------------------
# Cloud NAT — Required for VMs without external IP to reach internet
# (apt-get, docker pull, gcloud storage, etc.)
# -------------------------------------------------------------------

resource "google_compute_router" "openclaw" {
  name        = "openclaw-router"
  region      = var.region
  network     = var.network
  description = "Router for Cloud NAT — enables outbound internet for VMs without external IP"
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
  name        = "allow-iap-ssh-openclaw"
  network     = var.network
  description = "Allow SSH access via IAP tunnel (35.235.240.0/20 is Google's IAP proxy range)"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IAP's IP range — see https://cloud.google.com/iap/docs/using-tcp-forwarding
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["openclaw"]
}

# -------------------------------------------------------------------
# Egress Firewall — Restrict outbound traffic
# Blocks reverse shells on non-standard ports (mitigates AuthTool, ClawHavoc attacks)
# -------------------------------------------------------------------

resource "google_compute_firewall" "allow_egress_https" {
  name      = "allow-egress-https-openclaw"
  network   = var.network
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["443", "80"]
  }

  target_tags = ["openclaw"]
  description = "Allow HTTPS/HTTP outbound for Docker Hub, GCR, GCS, apt repos, Secret Manager APIs"
}

resource "google_compute_firewall" "allow_egress_dns" {
  name      = "allow-egress-dns-openclaw"
  network   = var.network
  direction = "EGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["53"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }

  target_tags = ["openclaw"]
  description = "Allow DNS resolution"
}

resource "google_compute_firewall" "deny_egress_all" {
  name      = "deny-egress-all-openclaw"
  network   = var.network
  direction = "EGRESS"
  # Priority 65534: just below GCP's implied deny-all (65535), overrides default allow-egress (65534)
  priority = 65534

  deny {
    protocol = "all"
  }

  target_tags = ["openclaw"]
  description = "Deny all other egress — prevents C2 callbacks on non-standard ports"
}
