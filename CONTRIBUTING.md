# Contributing to create-openclaw-agent

Thank you for your interest in contributing! This document will help you get started.

## Code of Conduct

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## How to Contribute

### Reporting Bugs

- Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md) when opening an issue
- Include: OS, cloud provider, steps to reproduce, and error messages
- Never include API keys, credentials, or personal data

### Suggesting Features

- Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md)
- Describe the use case and proposed solution
- Check existing issues first to avoid duplicates

### Pull Requests

1. **Fork** the repository and create a branch from `main`
2. **Make your changes** — keep PRs focused and small when possible
3. **Run checks locally** before pushing:
   ```bash
   shellcheck -x lib/*.sh providers/gcp/provider.sh providers/gcp/scripts/restore.sh setup.sh install.sh
   cd providers/gcp/infra && tofu init -backend=false && tofu validate
   ```
4. **Verify no secrets** in your diff:
   ```bash
   git diff --cached | grep -iE 'sk-|api.key|secret|token.*=.*[a-z0-9]{20}'
   # Should return nothing
   ```
5. **Push** and open a PR — the [PR template](.github/PULL_REQUEST_TEMPLATE.md) will guide you

### Commit Messages

- Use present tense: "Add X" not "Added X"
- Keep the first line under 72 characters
- Reference issues when applicable: "Fix SSH timeout (#42)"

## Adding a New Cloud Provider

AWS and Azure contributions are welcome. Follow this checklist:

1. **Create the provider structure:**
   ```
   providers/<cloud>/
   ├── provider.sh      # Implements the provider interface
   ├── infra/           # Terraform/OpenTofu files
   └── scripts/
       └── restore.sh
   ```

2. **Implement all required functions** in `provider.sh`:
   - `provider_check_prerequisites()` — CLI installed, authenticated, APIs enabled
   - `provider_store_secret()` / `provider_get_secret()`
   - `provider_provision_infra()` / `provider_destroy_infra()`
   - `provider_ssh_command()` / `provider_ssh_exec()`
   - `provider_upload_backup()` / `provider_download_backup()` / `provider_list_backups()`
   - `provider_wait_for_vm()` / `provider_check_resources()`

3. **Update** `setup.sh` cloud selection menu to include the new provider

4. **Add pricing data** to `lib/pricing.sh` for cost estimates

5. **Document** in `docs/<cloud>-guide.md` (IAM, secret manager, SSH access, troubleshooting)

6. **Add CI** validation for the new provider's Terraform (optional, can follow in a separate PR)

See `providers/gcp/provider.sh` for the reference implementation.

## Security — Never Commit Secrets

Before any commit, ensure:

- No API keys (`sk-`, `AKIA`, etc.)
- No `terraform.tfvars`, `backend.tfvars`, or `.env` files
- No `openclaw.json`, `agent-config.yml` with real data, or `docker-compose.override.yml`

If you accidentally commit a secret, rotate it immediately and use `git filter-branch` or [BFG Repo-Cleaner](https://rsc.io/bfg/) to remove it from history.

## Development Setup

```bash
git clone https://github.com/feliperbroering/create-openclaw-agent.git
cd create-openclaw-agent
./setup.sh   # Or run specific flows for testing
```

## Questions?

Open a [discussion](https://github.com/feliperbroering/create-openclaw-agent/discussions) or an issue with the `question` label.
