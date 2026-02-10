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
+-- GCE VM (e2-medium, IAP only, egress 80/443/53) -+
|                                                    |
|  Docker (bridge network: openclaw-net)             |
|   +- openclaw-gateway (Claude Sonnet 4)            |
|   |   ports: 127.0.0.1 only                       |
|   |   read_only, cap_drop:ALL, no-new-privileges   |
|   |   +- Memory: Mem0 OSS (Qdrant vectors)        |
|   |   +- Audio: Voxtral Mini (Mistral)             |
|   |   +- Browser: Chrome CDP (headless)            |
|   |   +- Channel: WhatsApp                         |
|   +- qdrant (vector store, read_only, cap_drop)    |
|   +- chrome (headless browser, read_only, cap_drop)|
|                                                    |
|  /run/openclaw-secrets/  (tmpfs, RAM only)         |
|   +- secrets.env          (fetched from SM)        |
|                                                    |
|  ~/.openclaw/                                      |
|   +- openclaw.json, credentials/, memory/          |
|   +- browser/chrome-data/                          |
|   +- workspace/ (SOUL.md, IDENTITY.md, etc.)       |
|                                                    |
|  Cron: backup (age-encrypted) -> GCS every 6h      |
+----------------------------------------------------+
         |                         ^
         v                         | Secrets at boot
+- GCS Bucket ----------+   +- Secret Manager ------+
| /backups/              |   | openclaw-anthropic-key |
| /tofu/state/           |   | openclaw-openai-key    |
+------------------------+   | openclaw-mistral-key   |
                              | openclaw-gateway-token |
                              +------------------------+
```

## Security

Defense-in-depth hardening across every layer. See [`docs/security.md`](docs/security.md) for the full architecture and threat model.

- VM has **no external IP** — access only via [IAP tunnel](https://cloud.google.com/iap/docs/using-tcp-forwarding)
- **Egress firewall** — outbound restricted to ports 80, 443, and 53 only (all other egress denied)
- All API keys in **Secret Manager** — fetched into tmpfs (RAM) at boot, never persisted to disk
- **Container hardening** — bridge network (not host), read-only filesystems, all capabilities dropped (`cap_drop: ALL`), `no-new-privileges`, resource limits, images pinned by SHA256 digest
- Service account follows **least privilege** (logging, monitoring, storage, secretAccessor — no delete)
- Shielded VM with Secure Boot, OS Login (IAM-based SSH)
- **Backups encrypted** with [age](https://age-encryption.org/) before upload to GCS; key in Secret Manager
- **Pre-commit hooks** — gitleaks, shellcheck, terraform-fmt, terraform-validate
- **CI scanning** — gitleaks (secrets), Trivy (container vulnerabilities), all GitHub Actions SHA-pinned

### Pre-commit hooks

Install to catch secrets and lint errors before they reach the repo:

```bash
pip install pre-commit && pre-commit install
```

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

Backups happen automatically every 6 hours and on every VM reboot. Last 30 backups retained. Backups are **encrypted with [age](https://age-encryption.org/)** before upload — the encryption key is stored in Secret Manager, never on disk.

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

> **Note:** API keys are NOT in backups — they're in Secret Manager. Backups are encrypted at rest with `age`. Restore handles both encrypted and unencrypted (legacy) backups. WhatsApp session may need re-pairing after restore.

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
├── scripts/
│   ├── run-e2e.sh                 # E2E test runner
│   └── verify-e2e-cleanup.sh     # Post-E2E resource cleanup verification
├── docs/
│   ├── gcp-guide.md               # GCP setup, Secret Manager, IAM
│   ├── mem0-setup.md              # Mem0 plugin configuration
│   └── security.md                # Full security architecture
├── .gitleaks.toml                 # Gitleaks secret scanning config
└── .pre-commit-config.yaml        # Pre-commit hooks
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
