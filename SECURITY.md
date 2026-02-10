# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

We release patches for security vulnerabilities in the latest major version.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

If you discover a security issue, please report it by one of these means:

1. **Private Security Advisory** (preferred): On GitHub, go to [Security → Advisories](https://github.com/feliperbroering/create-openclaw-agent/security/advisories) and click "Report a vulnerability" to open a private advisory.

2. **Email**: If you prefer not to use GitHub advisories, email the maintainer directly (check the repository for contact information).

When reporting, please include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if you have one)

**We aim to respond within 48 hours** and will keep you updated on progress. We appreciate your efforts to disclose your findings responsibly.

## Security Model

create-openclaw-agent is designed with security in mind:

- **No secrets on disk**: API keys and tokens are stored in cloud Secret Manager and fetched into tmpfs (RAM) at VM boot
- **VM isolation**: No external IP; access only via IAP tunnel or equivalent
- **Least privilege**: Service accounts with minimal required roles
- **Backups**: Exclude secrets; `.env` symlink points to tmpfs, not persisted

If you find a weakness in this model or in the implementation, we want to know.

## Acknowledgments

We thank security researchers who report vulnerabilities responsibly. Contributors who help fix security issues will be credited in release notes (unless they prefer to remain anonymous).
