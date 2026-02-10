# Security Architecture

> **create-openclaw-agent** is designed as a defense-in-depth reference implementation for self-hosted OpenClaw deployments. Every layer — from secrets management to container runtime to network egress — is hardened against the specific attack vectors documented in real-world OpenClaw exploitation campaigns.

---

## Table of Contents

- [Threat Model](#threat-model)
- [Defense Layers](#defense-layers)
  - [1. Secrets Management](#1-secrets-management)
  - [2. Network Isolation](#2-network-isolation)
  - [3. Container Hardening](#3-container-hardening)
  - [4. Infrastructure Security](#4-infrastructure-security)
  - [5. Backup Security](#5-backup-security)
  - [6. Supply Chain Security](#6-supply-chain-security)
  - [7. CI/CD Security](#7-cicd-security)
- [Mapping to Bitdefender Attack Vectors](#mapping-to-bitdefender-attack-vectors)
- [File Ownership and Permissions](#file-ownership-and-permissions)
- [Secrets Flow](#secrets-flow)
- [Verifying Security Posture](#verifying-security-posture)
- [References](#references)

---

## Threat Model

In February 2026, Bitdefender published a [Technical Advisory on OpenClaw Exploitation in Enterprise Networks](https://businessinsights.bitdefender.com/technical-advisory-openclaw-exploitation-enterprise-networks) documenting four distinct attack campaigns targeting OpenClaw deployments. These represent the most comprehensive publicly documented threats against the OpenClaw ecosystem, and they form the basis of our security model.

### Documented Attack Vectors

**1. ClawHavoc — Social Engineering via Fake Error Messages**

Attackers craft messages that trick the OpenClaw agent into executing base64-encoded payloads disguised as diagnostic commands. The decoded payload typically establishes outbound connections to command-and-control infrastructure on non-standard ports.

**2. AuthTool — Dormant Malware Triggered by Natural Language**

A sophisticated campaign where dormant malware is activated through natural language prompts, instructing the agent to execute `curl` commands that download and run reverse shell binaries. The shells connect out on arbitrary high ports, bypassing naive firewall configurations that only restrict inbound traffic.

**3. Hidden Backdoor — Install-Time Exploitation via Setup Scripts**

Malicious modifications to installation scripts that inject persistent backdoors during the setup phase. These backdoors establish tunnels or modify system configurations to allow future unauthorized access, leveraging the elevated privileges typically required during software installation.

**4. Credential Exfiltration — Stealing .env Files with Plaintext API Keys**

The most straightforward attack: reading `.env` files that contain plaintext API keys (Anthropic, OpenAI, etc.) directly from disk. In default OpenClaw installations, these keys sit as readable files in the deployment directory, accessible to any process running as the same user or with elevated privileges.

### Design Response

create-openclaw-agent treats these four vectors as the primary threat model. Every architectural decision — from how secrets are stored, to which ports the VM can reach, to how containers are sandboxed — traces back to mitigating one or more of these attack patterns. The following sections detail each defense layer and its relationship to these threats.

---

## Defense Layers

### 1. Secrets Management

**Principle: Zero plaintext on persistent disk — ever.**

The default OpenClaw installation stores API keys in a `.env` file on the filesystem. This is the single largest attack surface documented in the Bitdefender advisory (Credential Exfiltration). create-openclaw-agent eliminates this vector entirely.

**How it works:**

- **Secrets stored in GCP Secret Manager.** During `setup.sh`, the user enters API keys interactively. Keys are transmitted directly to Secret Manager via the `gcloud` CLI and are never written to any file on the local or remote machine.

- **Fetched at boot into a tmpfs RAM disk.** The VM startup script (`startup.sh`) mounts a 1 MB tmpfs filesystem at `/run/openclaw-secrets/` with restrictive permissions:

  ```bash
  mount -t tmpfs -o size=1M,mode=700,uid=1000,gid=1000 tmpfs /run/openclaw-secrets
  ```

  Secrets are fetched from Secret Manager and written directly into files on this tmpfs mount. On reboot, power loss, or VM preemption, the tmpfs contents are irrecoverably wiped — there is no persistence layer.

- **`.env` is a symlink to tmpfs.** Docker Compose reads its environment from `~/openclaw/.env`, which is a symbolic link pointing to `/run/openclaw-secrets/.env`. The real `.env` file exists only in RAM:

  ```bash
  ln -sf /run/openclaw-secrets/.env ~/openclaw/.env
  ```

- **Secrets never exposed as shell variables.** The `.env` file is assembled by writing to the tmpfs file directly using a heredoc with `cat` substitution. Individual secret files are deleted immediately after being incorporated into the `.env`. At no point do API keys appear in the process environment of the startup script itself.

- **Gateway token auto-generated with 256-bit entropy.** If no gateway token exists in Secret Manager, `setup.sh` generates one using `openssl rand -hex 32` (256 bits of cryptographic randomness) and stores it directly in Secret Manager.

**What this mitigates:** Credential Exfiltration — even if an attacker gains filesystem read access, there is nothing to steal. The `.env` symlink target exists only in volatile memory.

---

### 2. Network Isolation

**Principle: No inbound exposure, minimal outbound surface.**

Most OpenClaw exploitation campaigns depend on the attacker's ability to establish outbound connections from the compromised host. create-openclaw-agent makes this structurally impossible for non-standard protocols.

**How it works:**

- **No external IP address.** The VM is provisioned without any public IP. The `network_interface` block in Terraform deliberately omits `access_config`, meaning the VM cannot be reached from the internet and cannot initiate connections without Cloud NAT:

  ```hcl
  network_interface {
    network = var.network
    # No external IP — access via IAP tunnel only
  }
  ```

- **SSH access only through IAP tunnel.** The sole firewall ingress rule permits TCP port 22 from Google's IAP IP range (`35.235.240.0/20`) to instances tagged `openclaw`. All SSH sessions are authenticated through IAM identity, logged, and auditable.

- **Egress firewall restricts outbound to ports 80, 443, and 53 only.** Three firewall rules work together to create a strict egress allowlist:

  | Rule | Priority | Action | Ports | Purpose |
  |------|----------|--------|-------|---------|
  | `allow-egress-https-openclaw` | 1000 | Allow | TCP 443, 80 | Docker Hub, GCR, GCS, apt repos, APIs |
  | `allow-egress-dns-openclaw` | 1000 | Allow | TCP/UDP 53 | DNS resolution |
  | `deny-egress-all-openclaw` | 65534 | Deny | All | Block everything else |

  This architecture blocks reverse shells on non-standard ports (the primary mechanism of both ClawHavoc and AuthTool), command-and-control callbacks, and data exfiltration over non-HTTP protocols.

- **Cloud NAT for outbound connectivity.** Since the VM has no external IP, a Cloud NAT gateway (`google_compute_router_nat`) provides outbound internet access for legitimate operations (package updates, Docker image pulls, API calls to Secret Manager and GCS). Inbound connections remain impossible.

**What this mitigates:** ClawHavoc (base64 payloads cannot phone home on non-standard ports), AuthTool (reverse shells are blocked at the network level regardless of what runs on the VM).

---

### 3. Container Hardening

**Principle: Minimize the blast radius of any in-container compromise.**

Even if an attacker achieves code execution inside a container, the hardening measures ensure they cannot escalate privileges, modify binaries, access the host network, or persist across restarts.

All three containers (gateway, Qdrant, Chrome) are hardened with the following measures:

- **Bridge network, not host.** Containers communicate over an isolated Docker bridge network (`openclaw-net`). Gateway ports are bound exclusively to `127.0.0.1`, preventing any external access to the services even from within the VPC:

  ```yaml
  ports:
    - "127.0.0.1:18789:18789"
    - "127.0.0.1:18790:18790"
  ```

- **Read-only root filesystem.** Every container runs with `read_only: true`, preventing an attacker from modifying binaries, installing backdoors, dropping malware, or tampering with application code:

  ```yaml
  read_only: true
  tmpfs:
    - /tmp:size=100M
    - /home/node/.cache:size=50M
  ```

  Writable paths are limited to size-constrained tmpfs mounts for `/tmp` and application caches. These are volatile and disappear on container restart.

- **All Linux capabilities dropped.** Every container specifies `cap_drop: [ALL]`, removing all 41 Linux capabilities including the ability to create raw sockets, change file ownership, bind to privileged ports, or load kernel modules. The Chrome container receives only the single `SYS_ADMIN` capability required for headless browser operation:

  ```yaml
  cap_drop: [ALL]
  cap_add: [SYS_ADMIN]  # Chrome only
  ```

- **No new privileges.** The `no-new-privileges` security option prevents any process inside the container from gaining additional privileges through setuid/setgid binaries, `execve` calls, or other escalation mechanisms:

  ```yaml
  security_opt:
    - no-new-privileges:true
  ```

- **Resource limits prevent denial-of-service.** Each container has explicit CPU and memory limits that prevent resource exhaustion attacks from impacting the host or other containers:

  | Container | CPU Limit | Memory Limit |
  |-----------|-----------|--------------|
  | Gateway   | 1.5 cores | 1536 MB      |
  | Qdrant    | 0.5 cores | 512 MB       |
  | Chrome    | 0.5 cores | 1024 MB      |

- **Images pinned by version and SHA256 digest.** Every third-party image is pinned to both a version tag and its content-addressable SHA256 digest, preventing supply chain attacks via tag overwriting or registry compromise:

  ```yaml
  image: qdrant/qdrant:v1.13.2@sha256:81bdf0a9deedbeec68eed207145ade0b9d5db15e...
  image: chromedp/headless-shell:145.0.7632.46@sha256:478f1105d06e921d7652c18ecf6d1fc...
  ```

- **Health checks on all containers.** Each container declares a health check with defined intervals, timeouts, and retry counts. Docker will automatically restart unhealthy containers, limiting the window of any compromised state.

- **Log rotation configured.** The `json-file` logging driver with size and count limits prevents log-based disk exhaustion attacks.

**What this mitigates:** ClawHavoc (cap_drop prevents raw socket creation for custom protocols), AuthTool (read-only filesystem prevents downloading/installing reverse shell binaries, no-new-privileges blocks escalation), Hidden Backdoor (read-only filesystem prevents persistent modification).

---

### 4. Infrastructure Security

**Principle: Harden the platform beneath the containers.**

- **Shielded VM with Secure Boot.** The Compute Engine instance enables `enable_secure_boot = true`, which verifies the integrity of the boot chain and prevents boot-level rootkits or firmware tampering:

  ```hcl
  shielded_instance_config {
    enable_secure_boot = true
  }
  ```

- **OS Login ties SSH access to IAM identity.** With `enable-oslogin = "TRUE"` in instance metadata, SSH access is governed by IAM roles rather than static SSH keys distributed as files. Every login is authenticated against Google Cloud identity and logged.

- **Least-privilege IAM.** The VM's service account is granted only the minimum roles required for operation:

  | IAM Role | Purpose |
  |----------|---------|
  | `roles/secretmanager.secretAccessor` | Read secrets at boot |
  | `roles/storage.objectViewer` | Download backups from GCS |
  | `roles/storage.objectCreator` | Upload backups to GCS (no delete) |
  | `roles/logging.logWriter` | Write application logs to Cloud Logging |
  | `roles/monitoring.metricWriter` | Write metrics to Cloud Monitoring |

  Notably absent: `storage.objectAdmin` or any delete permissions on GCS. The VM can create and read backups but cannot delete them, protecting against ransomware or accidental data loss.

- **OAuth scopes narrowed to specific APIs.** Beyond IAM roles, the instance's OAuth scopes are restricted to only the Google APIs the VM actually needs (`secretmanager`, `devstorage.full_control`, `logging.write`, `monitoring.write`, `compute.readonly`).

- **Automatic security updates.** The startup script installs `unattended-upgrades` configured with `Automatic-Reboot "false"` — security patches are applied automatically, but the VM is never rebooted without operator consent (avoiding unexpected downtime for a messaging agent).

- **Dedicated `openclaw` user.** The startup script creates a dedicated system user (`openclaw`, UID 1000) and drops privileges from root as early as possible. The root-level startup script performs only system-level operations (package installation, tmpfs mounting, cron configuration) before handing off to the unprivileged user context.

**What this mitigates:** Hidden Backdoor (Secure Boot prevents boot-level persistence, OS Login eliminates static SSH key theft), credential escalation (least-privilege IAM limits lateral movement).

---

### 5. Backup Security

**Principle: Protect data at rest with client-side encryption and access controls.**

- **Client-side encryption with `age` before upload.** Backups are encrypted locally using [age](https://age-encryption.org/), a modern, audited encryption tool, before being uploaded to GCS. The encryption happens on the VM — Google Cloud Storage never sees unencrypted backup data.

- **Encryption key stored in Secret Manager.** The `age` private key is stored in GCP Secret Manager alongside other secrets, never on persistent disk. It is fetched into tmpfs at boot and used only for backup/restore operations.

- **Backward compatible restore.** The restore logic can handle both encrypted and unencrypted backups, supporting migration from older deployments that pre-date the encryption feature.

- **Bucket versioning enabled.** GCS object versioning is enabled on the backup bucket (`versioning { enabled = true }`), protecting against accidental or malicious overwrites. Even if a `latest` backup is replaced, previous versions are preserved.

- **Lifecycle rules handle retention.** GCS lifecycle rules automatically delete objects older than the configured retention period (`backup_retention_days`). Since the VM service account has `objectCreator` but not `objectAdmin` or delete permissions, retention is enforced by GCS policy — not by the VM itself.

- **Data Access audit logging.** Cloud Audit Logs are configured for both `DATA_READ` and `DATA_WRITE` operations on the storage API, providing a complete audit trail of all backup access:

  ```hcl
  resource "google_project_iam_audit_config" "storage_audit" {
    service = "storage.googleapis.com"
    audit_log_config { log_type = "DATA_READ" }
    audit_log_config { log_type = "DATA_WRITE" }
  }
  ```

**What this mitigates:** Credential Exfiltration (encrypted backups are useless without the key), data tampering (versioning preserves history), insider threats (audit logging creates accountability).

---

### 6. Supply Chain Security

**Principle: Verify everything. Trust nothing implicitly.**

Supply chain attacks compromise the tools and dependencies you trust. create-openclaw-agent pins, hashes, and scans every external dependency.

- **All GitHub Actions SHA-pinned.** Every action in the CI pipeline is referenced by its full commit SHA, not a mutable tag. This prevents tag overwrite attacks where a compromised action maintainer pushes malicious code to an existing tag:

  ```yaml
  - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
  - uses: gitleaks/gitleaks-action@ff98106e4c7b2bc287b24eaf42907196329070c7 # v2.3.9
  - uses: aquasecurity/trivy-action@b6643a29fecd7f34b3597bc6acb0a98b03d33ff8 # v0.33.1
  ```

- **Docker images pinned by version + content digest.** As described in [Container Hardening](#3-container-hardening), every third-party image is referenced by both its semantic version tag and its SHA256 content digest.

- **gitleaks scans for secrets in CI.** The `secrets-check` CI job runs [gitleaks](https://github.com/gitleaks/gitleaks) across the full git history on every push and pull request, configured with a project-specific `.gitleaks.toml` that defines allowlists for documentation files while catching real credential patterns.

- **Trivy scans container images for vulnerabilities.** The `image-scan` CI job uses [Trivy](https://github.com/aquasecurity/trivy) to scan all third-party container images for known vulnerabilities. Qdrant is scanned at CRITICAL and HIGH severity with exit-code 1 (build fails). Chrome is scanned at CRITICAL severity.

- **Pre-commit hooks enforce local hygiene.** The `.pre-commit-config.yaml` configures four hooks that run before every commit:

  | Hook | Purpose |
  |------|---------|
  | `gitleaks` | Scan staged changes for secrets |
  | `shellcheck` | Lint shell scripts for bugs and security issues |
  | `terraform-fmt` | Enforce consistent Terraform formatting |
  | `terraform-validate` | Validate Terraform configuration |

- **Comprehensive `.gitignore`.** The `.gitignore` blocks all sensitive file patterns: `.env`, `*.tfvars`, `*.tfstate`, `openclaw.json`, `agent-config.yml`, `docker-compose.override.yml`, and more. This is the last line of defense against accidental secret commits.

- **Checksum verification on install with hard-fail.** The `install.sh` script downloads release tarballs with SHA256 checksum verification. If checksums are available and verification fails, the install aborts immediately with a non-zero exit code — no fallback, no override:

  ```bash
  if ! (cd /tmp && sha256sum -c coa-sha256 2>/dev/null); then
    echo "ERROR: Checksum verification FAILED — download may be tampered with."
    exit 1
  fi
  ```

**What this mitigates:** Hidden Backdoor (checksum verification prevents tampered install scripts, SHA-pinned actions prevent CI supply chain attacks), all vectors (Trivy catches known vulnerabilities in dependencies before deployment).

---

### 7. CI/CD Security

**Principle: The build pipeline itself must be locked down.**

- **Workflow permissions restricted to `contents: read`.** The GitHub Actions workflow declares the minimum permission at the top level, preventing any job from writing to the repository, creating releases, or modifying settings:

  ```yaml
  permissions:
    contents: read
  ```

- **ShellCheck linting on all shell scripts.** Every shell script in the project (`lib/*.sh`, `setup.sh`, `install.sh`, provider scripts) is linted with [ShellCheck](https://www.shellcheck.net/) using the `-x` flag (follow sourced files). ShellCheck catches common security mistakes like unquoted variables, unsafe glob patterns, and command injection vulnerabilities.

- **Terraform validation and format checking.** `tofu validate` ensures the infrastructure configuration is syntactically correct and internally consistent. `tofu fmt -check` enforces canonical formatting, making it harder to hide malicious changes in formatting noise.

- **YAML linting on templates.** `yamllint` validates the Docker Compose and agent config templates, preventing malformed YAML from introducing unexpected behavior in production.

**What this mitigates:** Hidden Backdoor (CI catches malicious modifications before they reach production), Credential Exfiltration (gitleaks prevents accidental secret commits).

---

## Mapping to Bitdefender Attack Vectors

The following table maps each documented attack vector to the specific defense layers that neutralize it:

| Attack Vector | Primary Mitigation | Defense Layers |
|---|---|---|
| **ClawHavoc** — Social engineering → base64 payload that phones home | Egress firewall blocks outbound connections on all ports except 80, 443, 53. `cap_drop: ALL` prevents raw socket creation for custom protocols. Bridge network isolates containers from host networking. | Network Isolation, Container Hardening |
| **AuthTool** — Natural language triggers reverse shell via `curl` | Egress firewall restricts to 80/443/53 (reverse shells typically use high ports). `no-new-privileges` blocks privilege escalation. Read-only filesystem prevents downloading/installing shell binaries. | Network Isolation, Container Hardening |
| **Hidden Backdoor** — Install-time exploitation via setup scripts | Checksum verification on `install.sh` with hard-fail. SHA-pinned GitHub Actions prevent CI pipeline compromise. Egress firewall blocks tunnel establishment. Secure Boot prevents boot-level persistence. `unattended-upgrades` patches OS vulnerabilities. | Supply Chain Security, Network Isolation, Infrastructure Security |
| **Credential Exfiltration** — Stealing `.env` files with API keys | `.env` is a symlink to tmpfs (RAM only). Secrets never written to persistent disk. No shell variable exposure during secret handling. Individual key files deleted after aggregation. Backup encryption prevents extraction from GCS. | Secrets Management, Backup Security |

---

## File Ownership and Permissions

The project follows a strict ownership model that aligns the container's internal user with the host filesystem:

| Path | Owner | Mode | Notes |
|------|-------|------|-------|
| `/run/openclaw-secrets/` (tmpfs mount) | 1000:1000 | 700 | Only the `openclaw` user can read/write/traverse |
| `/run/openclaw-secrets/.env` | 1000:1000 | 600 | Secrets file — owner read/write only |
| `~/openclaw/.env` (symlink) | — | — | Symlink to `/run/openclaw-secrets/.env` |
| `~/.openclaw/` (data directory) | 1000:1000 | — | Recursive `chown 1000:1000` after restore |
| `~/openclaw/` (Docker Compose directory) | 1000:1000 | — | Docker config and symlinks |

- **Container runs as UID 1000** — the `node` user inside the OpenClaw gateway container.
- **Host files owned by 1000:1000** — the `openclaw` system user created by the startup script (`useradd` assigns UID 1000 by default on a fresh VM).
- **Startup script runs as root** (GCE metadata startup scripts execute as root) and drops to the `openclaw` user context as early as possible after completing privileged operations (package installation, tmpfs mounting, cron configuration).

---

## Secrets Flow

The following diagram traces the lifecycle of a secret from initial entry to container consumption:

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. SETUP (user's local machine)                                 │
│    setup.sh prompts for API keys                                │
│    → gcloud secrets create ... --data-file=-                    │
│    → Keys go directly to Secret Manager (never touch disk)      │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. BOOT (GCE startup script, runs as root)                      │
│    mount -t tmpfs ... /run/openclaw-secrets/                    │
│    gcloud secrets versions access latest → /run/.../key files   │
│    Assemble .env on tmpfs from key files                        │
│    Delete individual key files                                  │
│    ln -sf /run/openclaw-secrets/.env ~/openclaw/.env            │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. RUNTIME (Docker Compose)                                     │
│    docker compose reads .env (symlink → tmpfs)                  │
│    Injects ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.              │
│    as container environment variables                           │
│    Secrets exist only in container process memory               │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. REBOOT / POWER LOSS                                          │
│    tmpfs wiped (volatile memory)                                │
│    All secrets gone from the VM                                 │
│    Startup script re-fetches from Secret Manager on next boot   │
└─────────────────────────────────────────────────────────────────┘
```

At no point in this lifecycle do secrets exist on persistent storage (disk, SSD, or any durable medium on the VM).

---

## Verifying Security Posture

After deployment, run the following commands on the VM to verify that all security measures are correctly in place.

### Verify .env is a symlink to tmpfs

```bash
ls -la ~/openclaw/.env
# Expected: .env -> /run/openclaw-secrets/.env
```

### Verify tmpfs is mounted with correct permissions

```bash
mount | grep openclaw-secrets
# Expected: tmpfs on /run/openclaw-secrets type tmpfs (rw,relatime,size=1024k,mode=700,uid=1000,gid=1000)
```

### Verify no external IP on the VM

```bash
gcloud compute instances describe openclaw-gw \
  --format="value(networkInterfaces[0].accessConfigs)"
# Expected: empty output (no access config = no external IP)
```

### Verify egress firewall rules

```bash
gcloud compute firewall-rules list \
  --filter="name~openclaw" \
  --format="table(name,direction,allowed,denied)"
# Expected:
#   allow-egress-https-openclaw   EGRESS   tcp:443,80     —
#   allow-egress-dns-openclaw     EGRESS   tcp:53,udp:53  —
#   deny-egress-all-openclaw      EGRESS   —              all
#   allow-iap-ssh-openclaw        INGRESS  tcp:22         —
```

### Verify container filesystem is read-only

```bash
docker exec openclaw-openclaw-gateway-1 touch /test-write 2>&1
# Expected: touch: cannot touch '/test-write': Read-only file system
```

### Verify all Linux capabilities are dropped

```bash
docker exec openclaw-openclaw-gateway-1 cat /proc/1/status | grep -i cap
# Expected: CapEff should show 0000000000000000 (no effective capabilities)
```

### Verify no-new-privileges is set

```bash
docker inspect openclaw-openclaw-gateway-1 \
  --format='{{.HostConfig.SecurityOpt}}'
# Expected: [no-new-privileges:true]
```

### Verify container resource limits

```bash
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"
# Verify limits match: gateway 1.5CPU/1536MB, qdrant 0.5CPU/512MB, chrome 0.5CPU/1024MB
```

### Verify images are digest-pinned

```bash
docker inspect openclaw-openclaw-gateway-1 --format='{{.Image}}'
# Should return a sha256: prefixed digest, not a tag
```

### Verify Shielded VM Secure Boot

```bash
gcloud compute instances describe openclaw-gw \
  --format="value(shieldedInstanceConfig.enableSecureBoot)"
# Expected: True
```

### Verify OS Login is enabled

```bash
gcloud compute instances describe openclaw-gw \
  --format="value(metadata.items[0].value)" \
  --flatten="metadata.items" \
  --filter="metadata.items.key=enable-oslogin"
# Expected: TRUE
```

---

## References

- [Bitdefender Technical Advisory: OpenClaw Exploitation in Enterprise Networks (Feb 2026)](https://businessinsights.bitdefender.com/technical-advisory-openclaw-exploitation-enterprise-networks) — The threat intelligence report that defines this project's threat model.
- [CIS Docker Benchmark v1.7](https://www.cisecurity.org/benchmark/docker) — Industry standard for Docker container security. This project implements CIS recommendations for read-only filesystems (5.12), dropped capabilities (5.3), no-new-privileges (5.14), resource limits (5.10), and network segmentation (5.1).
- [GCP Security Best Practices](https://cloud.google.com/security/best-practices) — Google Cloud's reference architecture for secure workloads. This project follows recommendations for OS Login, Shielded VM, IAP tunneling, least-privilege IAM, and Secret Manager.
- [age encryption](https://age-encryption.org/) — The modern file encryption tool used for client-side backup encryption.
- [gitleaks](https://github.com/gitleaks/gitleaks) — Secret detection tool used in both CI and pre-commit hooks.
- [Trivy](https://github.com/aquasecurity/trivy) — Container image vulnerability scanner used in CI.
