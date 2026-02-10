# Google Cloud Platform — Setup Guide

Detailed guide for understanding and manually operating the GCP infrastructure behind create-openclaw-agent.

## Secret Manager

### How the setup automates secrets

During `setup.sh`, API keys are stored in Google Secret Manager:

```bash
# The setup creates secrets with the configured prefix (default: "openclaw")
gcloud secrets create openclaw-anthropic-api-key --replication-policy=automatic --labels=app=openclaw
echo -n "YOUR_API_KEY" | gcloud secrets versions add openclaw-anthropic-api-key --data-file=-
```

The VM's service account has `roles/secretmanager.secretAccessor`, allowing it to read secrets at boot time.

### Rotating a key

1. Update the secret in Secret Manager:

```bash
echo -n "new-key-value" | gcloud secrets versions add openclaw-anthropic-api-key --data-file=-
```

2. Reboot the VM or run the restart helper:

```bash
# On the VM:
~/openclaw-restart.sh

# Or remotely:
gcloud compute instances reset openclaw-gw --zone=YOUR_ZONE
```

The startup script re-fetches all secrets from Secret Manager on every boot.

### Adding a new secret

```bash
# Create the secret
gcloud secrets create openclaw-my-new-key --replication-policy=automatic --labels=app=openclaw

# Store the value
echo -n "value" | gcloud secrets versions add openclaw-my-new-key --data-file=-

# Update startup.sh to fetch and inject it into .env
```

### Listing secrets

```bash
gcloud secrets list --filter="labels.app=openclaw"
```

### Deleting a secret

```bash
gcloud secrets delete openclaw-mistral-api-key
```

## IAM and Permissions

The VM's service account (`openclaw-sa@PROJECT.iam.gserviceaccount.com`) has these roles:

| Role | Purpose |
|------|---------|
| `roles/logging.logWriter` | Write logs to Cloud Logging |
| `roles/monitoring.metricWriter` | Write metrics to Cloud Monitoring |
| `roles/storage.objectAdmin` | Read/write backups to GCS bucket |
| `roles/secretmanager.secretAccessor` | Read secrets from Secret Manager |

### Verifying permissions

```bash
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:openclaw-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

## IAP (Identity-Aware Proxy)

### How the tunnel works

The VM has no external IP. SSH access uses IAP's TCP forwarding:

```bash
gcloud compute ssh openclaw-gw --zone=YOUR_ZONE --tunnel-through-iap
```

IAP tunnels TCP traffic through Google's edge network. The firewall rule allows SSH (port 22) only from IAP's IP range (`35.235.240.0/20`).

### Adding another user

Grant the IAP-secured tunnel user role:

```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="user:other-user@gmail.com" \
  --role="roles/iap.tunnelResourceAccessor"
```

They also need `roles/compute.instanceAdmin.v1` or at least `compute.instances.setMetadata` to use OS Login SSH.

## Troubleshooting

### VM can't access Secret Manager

**Symptom:** Startup log shows "WARN: ANTHROPIC_API_KEY not found in Secret Manager"

**Fix:** Check IAM binding:

```bash
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/secretmanager.secretAccessor"
```

If the service account is missing, add it:

```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:openclaw-sa@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

### Startup script didn't run

**Check serial port output:**

```bash
gcloud compute instances get-serial-port-output openclaw-gw --zone=YOUR_ZONE | tail -50
```

**Check the startup log (if SSH works):**

```bash
sudo cat /var/log/openclaw-startup.log
```

### Containers keep restarting (OOM)

**Symptom:** `docker compose ps` shows containers in restart loop

**Cause:** VM doesn't have enough RAM. The 3 containers need ~3GB.

**Fix:** Upgrade to e2-medium (4GB) or larger:

```bash
# Update agent-config.yml
# machine_type: e2-medium

# Re-run setup
./setup.sh --config agent-config.yml
```

### Backup fails silently

**Check the backup log:**

```bash
sudo cat /var/log/openclaw-backup.log
```

**Run a manual backup to see errors:**

```bash
bash ~/openclaw-backup.sh
```

### Cannot SSH via IAP

**Check IAP firewall rule exists:**

```bash
gcloud compute firewall-rules describe allow-iap-ssh-openclaw
```

**Check your IAP permissions:**

```bash
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/iap.tunnelResourceAccessor AND bindings.members:user:YOUR_EMAIL"
```

## Useful Commands

```bash
# SSH into VM
gcloud compute ssh openclaw-gw --zone=ZONE --tunnel-through-iap

# View container status
docker compose ps

# View container logs
docker compose logs -f

# Manual backup
bash ~/openclaw-backup.sh

# List backups
gcloud storage ls gs://BUCKET/backups/

# Restart containers (re-fetches secrets)
~/openclaw-restart.sh

# View startup script log
sudo cat /var/log/openclaw-startup.log

# View backup log
sudo cat /var/log/openclaw-backup.log
```
