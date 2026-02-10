# create-openclaw-agent

Deploy a fully configured [OpenClaw](https://github.com/anthropics/openclaw) AI agent to the cloud in minutes.

```bash
curl -fsSL https://raw.githubusercontent.com/feliperbroering/create-openclaw-agent/main/install.sh | bash
```

## What You Get

- **Production-ready VM** with Docker (gateway + Qdrant + Chrome sidecar)
- **Mem0 persistent memory** — agent remembers across sessions
- **Chrome headless browser** — agent can browse the web
- **Audio transcription** via Voxtral Mini (Mistral)
- **WhatsApp channel** with debouncing and allowlist
- **Automated backups** to cloud storage every 6 hours
- **Auto-restore** on VM recreation from latest backup
- **Secrets in Secret Manager** — zero plaintext on disk
- **Cost estimate** shown before deploy (~$24-36/mo)
- **Portable config** — migrate between clouds with one file

## Supported Clouds

| Cloud | Status |
|-------|--------|
| Google Cloud Platform | Supported |
| Amazon Web Services | Contributions welcome |
| Microsoft Azure | Contributions welcome |

## Three Paths

### New Agent (fresh install)

The interactive wizard guides you through everything:

```bash
curl -fsSL https://raw.githubusercontent.com/feliperbroering/create-openclaw-agent/main/install.sh | bash
```

It will:
1. Install dependencies (gcloud, OpenTofu, etc.) with your confirmation
2. Walk you through GCP setup (account, project, billing, APIs)
3. Collect your API keys and store them in Secret Manager
4. Show a cost estimate before deploying
5. Provision infrastructure (VM, storage, firewall, IAM)
6. Deploy OpenClaw with all plugins configured
7. Generate your portable `agent-config.yml`

### Migrate to New Cloud/VM

```bash
./setup.sh --config agent-config.yml
```

Uses your existing `agent-config.yml` to recreate the agent on a new VM, region, or cloud. Secrets are migrated automatically between providers.

### Disaster Recovery

**Automatic:** If the VM is recreated (e.g., `tofu apply` after destroy), the startup script automatically restores from the latest backup.

**Manual:** SSH into any VM and run:

```bash
bash restore.sh YOUR_BUCKET_NAME
```

## Architecture

```
┌─ GCE VM (e2-medium, IAP only) ───────────────────┐
│                                                    │
│  Docker                                            │
│   ├─ openclaw-gateway (Claude Sonnet 4)            │
│   │   ├─ Memory: Mem0 OSS (Qdrant vectors)        │
│   │   ├─ Audio: Voxtral Mini (Mistral)             │
│   │   ├─ Browser: Chrome CDP (headless)            │
│   │   └─ Channel: WhatsApp                         │
│   ├─ qdrant (vector store sidecar)                 │
│   └─ chrome (headless browser sidecar)             │
│                                                    │
│  /run/openclaw-secrets/  (tmpfs — RAM only)        │
│   └─ secrets.env          (fetched from SM)        │
│                                                    │
│  ~/.openclaw/                                      │
│   ├─ openclaw.json, credentials/, memory/          │
│   ├─ browser/chrome-data/                          │
│   └─ workspace/ (SOUL.md, IDENTITY.md, etc.)       │
│                                                    │
│  Cron: backup → GCS every 6h + on reboot           │
└────────────────────────────────────────────────────┘
         │                         ▲
         ▼                         │ Secrets at boot
┌─ GCS Bucket ────────┐   ┌─ Secret Manager ────────┐
│ /backups/            │   │ openclaw-anthropic-key   │
│ /tofu/state/         │   │ openclaw-openai-key      │
└──────────────────────┘   │ openclaw-mistral-key     │
                           │ openclaw-gateway-token   │
                           └─────────────────────────┘
```

## Security

- VM has **no external IP** — access only via [IAP tunnel](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- All API keys in **Secret Manager** — fetched into tmpfs (RAM) at boot, never persisted to disk
- Service account follows **least privilege** (logging, monitoring, storage, secretAccessor)
- Docker runs with `no-new-privileges` security option
- Shielded VM with Secure Boot enabled
- Backups exclude secrets (`.env` is a symlink to tmpfs)

## Cost Estimate

For moderate personal use (~50 messages/day):

| Component | Monthly Cost |
|-----------|-------------|
| VM e2-medium (2 vCPU, 4GB) | $24.46 |
| Boot disk 20GB | $0.80 |
| GCS storage, Secret Manager, network | ~$0.77 |
| Claude Sonnet 4 (main agent) | ~$8 |
| Claude Haiku 4.5 (Mem0 extraction) | ~$1 |
| OpenAI embeddings | ~$0.01 |
| Mistral Voxtral (audio) | ~$1 |
| **Total** | **~$36/mo** |

With 1-year VM commitment: ~$26/mo. GCP offers $300 free trial (~12 months free).

## Backup & Restore

Backups happen automatically every 6 hours and on every VM reboot. Last 30 backups retained.

### What's backed up

| Item | Contains |
|------|----------|
| `openclaw.json` | Full config (model, plugins, channels) |
| `credentials/` | WhatsApp session, tokens |
| `identity/` | Device auth tokens |
| `agents/` | Auth profiles, sessions |
| `memory/` | Mem0 data (Qdrant vectors + history DB) |
| `extensions/` | Installed plugins (mem0) |
| `devices/`, `cron/` | Device registry, scheduled jobs |
| `browser/` | Chrome profile data (caches stripped) |
| `workspace/` | Agent persona (SOUL.md, IDENTITY.md, etc.) |
| `agent-config.yml` | Portable configuration |
| Docker config | docker-compose.yml + override |

> **Note:** API keys are NOT in backups — they're in Secret Manager. WhatsApp session may need re-pairing after restore.

## File Structure

```
.
├── install.sh                     # curl | bash entry point
├── setup.sh                       # Interactive setup wizard
├── lib/                           # Shared utilities
│   ├── common.sh                  # Colors, logging, prompts, deps
│   ├── config.sh                  # agent-config.yml management
│   ├── secrets.sh                 # Secret manager abstraction
│   ├── docker.sh                  # Docker setup and health checks
│   ├── pricing.sh                 # Cost estimation
│   └── backup.sh                  # Backup/restore logic
├── providers/
│   └── gcp/
│       ├── provider.sh            # GCP implementation
│       ├── infra/                 # Terraform (VM, bucket, IAM, secrets)
│       └── scripts/               # VM-side scripts (restore)
├── templates/                     # Config file templates
│   ├── docker-compose.override.example.yml
│   ├── env.example
│   └── agent-config.example.yml
└── docs/
    ├── gcp-guide.md               # GCP setup, Secret Manager, IAM
    └── mem0-setup.md              # Mem0 plugin configuration
```

## Contributing

We welcome contributions! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. By participating, you agree to our [Code of Conduct](CODE_OF_CONDUCT.md). To report security vulnerabilities, see [SECURITY.md](SECURITY.md).

### Adding a new cloud provider

Create `providers/<cloud>/provider.sh` implementing these functions:

```bash
provider_check_prerequisites()    # Verify CLI installed and authenticated
provider_store_secret()           # Store secret in key management service
provider_get_secret()             # Retrieve secret
provider_provision_infra()        # Run terraform/tofu
provider_ssh_command()            # Return SSH command for the VM
provider_upload_backup()          # Upload to cloud storage
provider_download_backup()        # Download from cloud storage
provider_list_backups()           # List available backups
provider_wait_for_vm()            # Wait for VM to be ready
provider_check_resources()        # Validate VM has enough resources
```

See `providers/gcp/provider.sh` for reference.

## License

MIT
