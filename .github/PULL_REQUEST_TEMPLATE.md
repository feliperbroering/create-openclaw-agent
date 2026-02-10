## Description

Brief description of the changes.

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] Refactor / code quality

## Checklist

- [ ] Shell scripts pass `shellcheck` (run locally or CI will catch it)
- [ ] No secrets in diff (verified with `git diff | grep -iE 'sk-|api.key|secret'`)
- [ ] Terraform validates (`tofu validate` in `providers/gcp/infra`)
- [ ] Documentation updated if needed (README, docs/, AGENTS.md)
