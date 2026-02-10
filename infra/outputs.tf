output "vm_name" {
  description = "Name of the GCE instance"
  value       = google_compute_instance.openclaw_gw.name
}

output "vm_zone" {
  description = "Zone of the GCE instance"
  value       = google_compute_instance.openclaw_gw.zone
}

output "service_account" {
  description = "Service account email"
  value       = google_service_account.openclaw.email
}

output "backup_bucket" {
  description = "GCS backup bucket URL"
  value       = google_storage_bucket.backup.url
}

output "ssh_command" {
  description = "SSH command to connect to the VM via IAP"
  value       = "gcloud compute ssh ${google_compute_instance.openclaw_gw.name} --zone=${google_compute_instance.openclaw_gw.zone} --tunnel-through-iap"
}
