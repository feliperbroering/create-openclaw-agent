# OpenClaw Self-Hosting on GCE

Infrastructure-as-Code template for self-hosting [OpenClaw](https://github.com/anthropics/openclaw) on Google Compute Engine with automated backups, persistent memory (Mem0), and disaster recovery.

## What You Get

- **GCE VM** (e2-small, no external IP, SSH via IAP only)
- **Mem0 memory plugin** with persistent SQLite vector store
- **Audio transcription** via Voxtral Mini (Mistral API)
- **Automated backups** to GCS every 6 hours
- **Auto-restore** on VM recreation from latest backup
- **OpenTofu/Terraform** for reproducible infrastructure

## Architecture

```
┌─ GCE VM (e2-small, IAP only) ────────────────┐
│                                                │
│  Docker                                        │
│   └─ openclaw-gateway                          │
│       ├─ Agent: Claude Haiku 4.5 (default)     │
│       ├─ Memory: Mem0 OSS (SQLite vectors)     │
│       ├─ Audio: Voxtral Mini (Mistral)         │
│       └─ Channel: WhatsApp                     │
│                                                │
│  ~/.openclaw/                                  │
│   ├─ openclaw.json        (config)             │
│   ├─ credentials/         (WhatsApp session)   │
│   ├─ memory/              (Mem0 SQLite DBs)    │
│   └─ workspace/           (agent persona)      │
│                                                │
│  Cron: backup → GCS every 6h                   │
└────────────────────────────────────────────────┘
          │
          ▼
┌─ GCS Bucket ──────────────────────────────────┐
│  /backups/openclaw-latest.tar.gz               │
│  /backups/openclaw-20260208-233427.tar.gz      │
│  /tofu/state/  (Terraform remote state)        │
└────────────────────────────────────────────────┘
```

## Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- [OpenTofu](https://opentofu.org/docs/intro/install/) or [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- A GCP project with billing enabled
- API keys:
  - **Anthropic** — for the agent LLM ([console.anthropic.com](https://console.anthropic.com))
  - **OpenAI** — for Mem0 embeddings ([platform.openai.com](https://platform.openai.com))
  - **Mistral** *(optional)* — for audio transcription ([console.mistral.ai](https://console.mistral.ai))

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USER/openclaw-gce.git
cd openclaw-gce/infra

# Copy example files
cp terraform.tfvars.example terraform.tfvars
cp backend.tfvars.example backend.tfvars

# Edit with your values
$EDITOR terraform.tfvars
$EDITOR backend.tfvars
```

### 2. Create the GCS bucket (first time only)

```bash
gcloud storage buckets create gs://YOUR_BUCKET_NAME \
  --location=YOUR_REGION \
  --uniform-bucket-level-access
```

### 3. Deploy infrastructure

```bash
tofu init -backend-config=backend.tfvars
tofu plan
tofu apply
```

### 4. SSH into the VM and setup OpenClaw

```bash
gcloud compute ssh openclaw-gw --zone=YOUR_ZONE --tunnel-through-iap

# On the VM:
mkdir -p ~/openclaw && cd ~/openclaw

# Copy docker-compose.yml from OpenClaw's repo
# Then create your .env (see docker/.env.example)
# Then create docker-compose.override.yml (see docker/docker-compose.override.example.yml)

docker compose up -d
```

### 5. Configure OpenClaw

```bash
docker exec -it openclaw-openclaw-gateway-1 node dist/index.js setup
docker exec -it openclaw-openclaw-gateway-1 node dist/index.js configure
```

## Backup & Restore

### Backups happen automatically

- Every 6 hours via cron
- On every VM reboot (after 5 min delay)
- Stored in your GCS bucket under `/backups/`
- Last 30 backups retained

### Manual backup

```bash
bash ~/openclaw-backup.sh
```

### List backups

```bash
gcloud storage ls gs://YOUR_BUCKET/backups/
```

### Restore (disaster recovery)

```bash
# On a fresh VM:
bash restore.sh YOUR_BUCKET_NAME

# Or from a specific backup:
bash restore.sh YOUR_BUCKET_NAME openclaw-20260208-233427.tar.gz
```

### What's backed up

| Item | Contains |
|------|----------|
| `openclaw.json` | Full config (model, plugins, channels) |
| `credentials/` | WhatsApp session, tokens |
| `agents/` | Auth profiles (API key references) |
| `memory/` | Mem0 SQLite databases (vectors + history) |
| `workspace/` | Agent persona (AGENTS.md, SOUL.md, etc.) |
| Docker config | .env, docker-compose files |

> **Note:** WhatsApp session may need re-pairing after restore.

## Mem0 Memory Plugin

The template configures [Mem0](https://mem0.ai) in open-source mode:

- **LLM**: Claude Haiku 4.5 (memory extraction)
- **Embedder**: OpenAI text-embedding-3-small
- **Vector Store**: SQLite (persistent, survives restarts)
- **Auto-Capture**: extracts facts from every conversation
- **Auto-Recall**: injects relevant memories before each response

## Security

- VM has **no external IP** — access only via [IAP tunnel](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- Service account follows **least privilege** (logging, monitoring, storage)
- Docker runs with `no-new-privileges` security option
- Shielded VM with Secure Boot enabled
- All secrets in `.env` and `terraform.tfvars` are **gitignored**

## File Structure

```
.
├── .gitignore                              # Comprehensive secret protection
├── README.md
├── docker/
│   ├── .env.example                        # Template for API keys
│   └── docker-compose.override.example.yml # Template for Docker config
└── infra/
    ├── main.tf                             # VM, bucket, IAM, firewall
    ├── variables.tf                        # All configurable parameters
    ├── outputs.tf                          # Useful output values
    ├── startup.sh                          # VM boot script (auto-restore)
    ├── restore.sh                          # Manual restore script
    ├── terraform.tfvars.example            # Template for Tofu variables
    └── backend.tfvars.example              # Template for state backend
```

## License

MIT
