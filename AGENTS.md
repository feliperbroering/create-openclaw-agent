# create-openclaw-agent — Agent Instructions

CLI tool for deploying self-hosted OpenClaw AI agents on cloud infrastructure. Supports GCP (with extensible provider interface for AWS, Azure).

## Project Structure

```
.
├── install.sh                     # curl | bash entry point (release-pinned)
├── setup.sh                       # Interactive wizard (new/migrate/restore)
├── lib/
│   ├── common.sh                  # Colors, logging, prompts, dependency mgmt
│   ├── config.sh                  # agent-config.yml generation and parsing
│   ├── secrets.sh                 # Abstract secret store/get/migrate interface
│   ├── docker.sh                  # Docker compose setup, health checks, plugins
│   ├── pricing.sh                 # Cost estimation (infra + LLM APIs)
│   └── backup.sh                  # Backup script generation, restore logic
├── providers/
│   └── gcp/
│       ├── provider.sh            # GCP: Secret Manager, Compute, GCS, IAP
│       ├── infra/
│       │   ├── main.tf            # VM, bucket, IAM, firewall, Secret Manager API
│       │   ├── variables.tf       # 13 variables (project, bucket, region, etc.)
│       │   ├── outputs.tf         # SSH command, bucket URL
│       │   └── startup.sh         # GCE startup (templatefile, auto-restore, tmpfs secrets)
│       └── scripts/
│           └── restore.sh         # Manual disaster recovery
├── templates/
│   ├── docker-compose.override.example.yml  # 3 containers: gateway, qdrant, chrome
│   ├── env.example                          # Non-secret env vars template
│   └── agent-config.example.yml             # Portable agent config template
├── docs/
│   ├── gcp-guide.md              # Secret Manager, IAM, IAP, troubleshooting
│   ├── mem0-setup.md             # Mem0 plugin setup guide
│   └── security.md               # Full security architecture document
├── .github/workflows/
│   └── validate.yml              # CI: shellcheck, tofu validate, smoke tests
├── scripts/
│   ├── run-e2e.sh                # E2E test runner (env-based API keys)
│   └── verify-e2e-cleanup.sh     # Post-E2E resource cleanup verification
├── .gitleaks.toml                # Gitleaks secret scanning config
├── .pre-commit-config.yaml       # Pre-commit hooks (gitleaks, shellcheck, tofu)
├── .gitignore
├── CLAUDE.md                     # Same as AGENTS.md
├── AGENTS.md                     # This file
├── LICENSE
└── README.md
```

## Key Architecture Decisions

- **Cloud-agnostic**: Provider interface in `providers/<cloud>/provider.sh`. GCP first; community adds AWS/Azure by implementing the same functions.
- **No external IP**: VM accessible only via IAP tunnel (GCP) or equivalent.
- **3 containers on bridge network**: OpenClaw gateway + Qdrant vector store + Chrome headless (CDP) on an isolated Docker bridge network (`openclaw-net`). Gateway ports bound to `127.0.0.1` only. Read-only root filesystems (`read_only: true`), all Linux capabilities dropped (`cap_drop: ALL`), `no-new-privileges`. Total resource needs: 2.5 CPU, 3GB RAM. Requires e2-medium or larger.
- **Secrets in Secret Manager**: Zero plaintext on disk. Startup script fetches secrets into tmpfs (`/run/openclaw-secrets/`). Symlinked as `.env` for Docker Compose.
- **agent-config.yml**: Portable personal config (no secrets). Single source of truth for infrastructure, LLMs, plugins, channels. Generates `terraform.tfvars` and Docker config.
- **Mem0 memory**: Qdrant vector store running as Docker sidecar. Data at `~/.openclaw/memory/qdrant/`. LLM extraction via Anthropic Haiku.
- **Egress firewall**: Outbound traffic restricted to ports 80, 443, and 53 only. All other egress denied. Cloud NAT provides outbound connectivity (no external IP).
- **Backup encryption**: Backups encrypted client-side with [age](https://age-encryption.org/) before upload to GCS. Encryption key stored in Secret Manager.
- **Auto-restore on fresh VM**: Startup script checks if `~/.openclaw/openclaw.json` exists; if not, downloads and restores from latest GCS backup. Handles both encrypted and unencrypted backups.
- **File ownership**: Container runs as UID 1000 (`node` user). Host files chown'd to 1000:1000.

## Security — CRITICAL Rules

Full security architecture documented in `docs/security.md`.

### Defense layers

1. **Secrets**: Secret Manager → tmpfs at boot → `.env` symlink. Zero plaintext on persistent disk.
2. **Network**: No external IP. IAP-only SSH. Egress firewall allows only ports 80/443/53.
3. **Containers**: Bridge network, `read_only: true`, `cap_drop: ALL`, `no-new-privileges`, resource limits, images pinned by SHA256 digest.
4. **Infrastructure**: Shielded VM + Secure Boot, OS Login (IAM-based SSH), least-privilege service account, `unattended-upgrades`.
5. **Backups**: Client-side `age` encryption before GCS upload. Key in Secret Manager. Bucket versioning enabled.
6. **Supply chain**: GitHub Actions SHA-pinned, Docker images digest-pinned, gitleaks + Trivy in CI, `install.sh` checksum verification with hard-fail.
7. **Pre-commit hooks**: gitleaks (secrets), shellcheck (shell bugs), terraform-fmt, terraform-validate. Install: `pip install pre-commit && pre-commit install`.

### NEVER commit secrets

The `.gitignore` blocks all sensitive files. Before ANY commit, verify:

1. **No API keys** in any file (grep for `sk-`, `api_key`, `token`, `secret`, `password`)
2. **No `terraform.tfvars`** or `terraform.auto.tfvars` or `backend.tfvars`
3. **No `.env`** files (only `.example` templates)
4. **No `openclaw.json`** (contains plugin configs with key references)
5. **No `*.tfstate`** files
6. **No `agent-config.yml`** with real phone numbers or personal data (only `.example` is safe)
7. **No `docker-compose.override.yml`** (may reference secrets via env vars)

### How secrets flow

```
setup.sh → user enters API keys → stored in Secret Manager (never disk)
startup.sh → fetches from Secret Manager → writes to tmpfs /run/openclaw-secrets/
docker compose → reads .env symlinked to tmpfs → injects as container env vars
reboot → tmpfs wiped → startup.sh re-fetches fresh secrets
```

### Verifying before push

```bash
git diff --cached --name-only | grep -E '\.env$|tfvars$|tfstate|openclaw\.json|agent-config\.yml|override\.yml'
# Should return nothing

git diff --cached | grep -iE 'sk-|api.key|secret|token.*=.*[a-z0-9]{20}'
# Should return nothing
```

## Working with Terraform/OpenTofu

### Variables

All values come from `agent-config.yml` via `config_generate_tfvars()` in `lib/config.sh`. Users never edit `.tfvars` directly.

Required: `project_id`, `backup_bucket_name`.
Optional with defaults: `region`, `zone`, `machine_type`, `disk_size_gb`, `timezone`, `vm_name`, `service_account_id`, `network`, `backup_retention_days`, `backup_cron_interval_hours`, `secrets_prefix`.

### startup.sh is a templatefile

Uses Terraform `${}` interpolation for: `${backup_bucket}`, `${timezone}`, `${backup_hours}`, `${secrets_prefix}`, `${backup_retention}`. Shell variables use `$${VAR}` syntax (Terraform renders `$$` as a literal `$`). Inside single-quoted heredocs (`<< 'EOF'`), plain `$VAR` works because Terraform only interpolates `${...}` patterns.

## Provider Interface

Each provider implements these functions in `providers/<cloud>/provider.sh`:

```bash
provider_check_prerequisites()    # CLI installed? Authenticated? Billing? APIs?
provider_store_secret()           # Store key in secret manager
provider_get_secret()             # Retrieve key from secret manager
provider_provision_infra()        # Run terraform/tofu
provider_destroy_infra()          # Destroy infrastructure
provider_ssh_command()            # SSH command string for the VM
provider_ssh_exec()               # Execute command on VM via SSH
provider_upload_backup()          # Upload to cloud storage
provider_download_backup()        # Download from cloud storage
provider_list_backups()           # List available backups
provider_wait_for_vm()            # Wait for VM to be running
provider_check_resources()        # Warn if VM too small for containers
```

## Backup Contents

Backups are encrypted with `age` before upload to GCS. The encryption key is stored in Secret Manager. Restore handles both encrypted and unencrypted (legacy) backups.

What the backup script (`openclaw-backup.sh`) saves:

- `openclaw.json` — full config
- `credentials/` — WhatsApp session keys
- `identity/` — device auth tokens
- `agents/` — auth profiles, sessions
- `memory/` — Mem0 data (Qdrant vectors + history DB + built-in search index)
- `extensions/` — installed plugins (openclaw-mem0)
- `devices/` — device registry
- `cron/` — scheduled jobs
- `canvas/`, `completions/`, `media/`, `subagents/` — runtime data
- `browser/` — Chrome profile data (caches stripped)
- `workspace/*.md` — agent persona files
- `agent-config.yml` — portable configuration
- Docker config — docker-compose.yml + override (NOT .env — secrets stay in SM)

## Making Changes

### Adding a new cloud provider

1. Create `providers/<cloud>/provider.sh` implementing all functions above
2. Add `infra/` directory with Terraform files for that cloud
3. Add `scripts/` directory with restore script
4. Update `setup.sh` cloud selection menu
5. Add pricing data to `lib/pricing.sh`
6. Document in `docs/<cloud>-guide.md`

### Adding a new backed-up directory

1. Add `docker cp` line in the backup script template (`startup.sh` section 6)
2. Add `cp -r` line in the restore section (`startup.sh` section 7)
3. Add same `cp -r` in `providers/gcp/scripts/restore.sh`
4. Add same in `lib/backup.sh` `restore_from_backup()` function
5. Update backup table in README.md

### Modifying Docker Compose security

When adding containers to `docker-compose.override.example.yml`, always include:
- `networks: [openclaw-net]` (bridge network, not host)
- `read_only: true` + `tmpfs` for writable paths
- `cap_drop: [ALL]` (add back only what's strictly required)
- `security_opt: [no-new-privileges:true]`
- `deploy.resources.limits` (CPU + memory)
- Image pinned by version + SHA256 digest
- Health check with interval/timeout/retries

### Modifying .gitignore

Only ADD patterns, never remove them. Use `!filename` to explicitly allow files.
