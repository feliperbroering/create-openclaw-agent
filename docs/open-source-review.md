# Review Final — create-openclaw-agent para Open Source

Análise do plano e código existente com foco em boas práticas de repositórios públicos e bastante utilizados. Inspirado em projetos como create-react-app, nvm, oh-my-zsh, e guias da Open Source Initiative.

---

## ✅ Pontos Fortes (já implementados ou no plano)

### Segurança
- **Secret Manager**: Zero plaintext em disco (tmpfs) — excelente
- **.gitignore robusto**: 80+ padrões, bloqueia tfstate, .env, credentials
- **CI secrets-check**: Detecta `sk-ant-`, `AKIA` no código
- **VM sem IP externo**: Acesso apenas via IAP tunnel
- **Least privilege**: Service account com roles mínimos

### Arquitetura
- **Provider interface**: Cloud-agnostic, fácil extensão para AWS/Azure
- **agent-config.yml portável**: Configuração divorciada de secrets
- **Healthchecks**: Gateway, Qdrant, Chrome com retries
- **Backup completo**: 12+ diretórios documentados

### CI/CD
- Shellcheck, tofu validate, yamllint
- Formato e validação automatizados

---

## 🔴 Lacunas Críticas (implementar antes do lançamento público)

### 1. Documentos de comunidade ausentes

Repositórios públicos maduros incluem:

| Documento | Status | Por que é importante |
|-----------|--------|----------------------|
| **CONTRIBUTING.md** | ❌ Ausente | Guia para PRs, style, como adicionar provider |
| **CODE_OF_CONDUCT.md** | ❌ Ausente | Requisito do GitHub, protege contribuidores |
| **SECURITY.md** | ❌ Ausente | Onde reportar vulnerabilidades, política de disclosure |
| **CHANGELOG.md** | ❌ Ausente | Histórico de mudanças, semver |
| **.github/ISSUE_TEMPLATE/** | ❌ Ausente | Bug, feature, config — estrutura issues |
| **.github/PULL_REQUEST_TEMPLATE.md** | ❌ Ausente | Checklist antes de merge |

**Ação**: Criar todos antes do primeiro release público.

### 2. Repo URL hardcoded

`feliperbroering/create-openclaw-agent` está fixo em:
- `install.sh` (REPO_URL, REPO_API)
- `README.md` (curl examples)

**Problema**: Se o repo for transferido para uma org (ex: `openclaw-community/create-openclaw-agent`), todos os curl quebram.

**Solução**:
- Usar variável de ambiente: `REPO=${GITHUB_REPO:-feliperbroering/create-openclaw-agent}`
- Ou, ao transferir, manter redirect do GitHub (301) — GitHub redireciona automaticamente por um tempo
- Documentar no README: "Fork? Use `REPO=seu-user/seu-fork install.sh`"

### 3. Supply chain do install.sh

**Situação atual**:
- Com releases: baixa tarball + verifica SHA256 ✓
- Sem releases: `git clone` de `main` — código em movimento

**Riscos**:
- `curl | bash` é controverso — alguns bloqueiam por política
- Commit malicioso em `main` afeta quem instala sem release

**Recomendações**:
1. **Primeiro release cedo**: Criar `v1.0.0` logo para estabilizar
2. **README "Modo verificado"**: Instruções para download manual + verificação de checksum
3. **Assinatura opcional**: Considerar `minisign` ou GPG para releases (futuro)
4. **Adicionar ao README**:
   ```markdown
   ## Alternative: Verified Install
   
   Download the release tarball and SHA256SUMS, verify checksums, then run:
   ```
   ```bash
   tar -xzf create-openclaw-agent-v1.0.0.tar.gz
   cd create-openclaw-agent-*
   ./setup.sh
   ```
   ```

### 4. LICENSE — Ano de copyright

```
Copyright (c) 2026 Felipe Broering
```

2026 está no futuro. Usar ano atual ou range: `2025-2026` ou apenas `2025`.

---

## 🟡 Melhorias Recomendadas

### 5. Contributing — Provider AWS/Azure

O plano diz "contributions welcome" para AWS/Azure. Para facilitar:

- **CONTRIBUTING.md** com seção explícita: "Adding a new cloud provider"
- Template/checklist: funções obrigatórias, como testar localmente
- Opcional: `docs/provider-interface.md` — especificação formal da interface

### 6. Issue templates

Criar `.github/ISSUE_TEMPLATE/`:

```
bug_report.md      — repro steps, OS, provider
feature_request.md — use case, proposed solution
config_help.md     — agent-config.yml (sem secrets!), logs
```

`config.yml` para escolher tipo ao abrir issue.

### 7. PR template

```markdown
## Description
## Type of change (bug fix / feature / docs)
## Checklist
- [ ] Shell scripts pass shellcheck
- [ ] No secrets in diff (ran grep check)
- [ ] Updated docs if needed
```

### 8. CHANGELOG e semver

- Manter `CHANGELOG.md` no estilo [Keep a Changelog](https://keepachangelog.com/)
- Tags: `v1.0.0`, `v1.1.0` (semver)
- Release notes no GitHub vinculando ao CHANGELOG

### 9. Badges no README

Para credibilidade imediata:

```markdown
[![CI](https://github.com/.../actions/workflows/validate.yml/badge.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)]()
```

### 10. smoke-test no CI (do plano)

O plano menciona:
```yaml
smoke-test:
  - Dry-run do setup.sh com inputs mockados
```

**Status**: Não implementado no `validate.yml` atual.

**Sugestão**: Adicionar job que:
- Roda `setup.sh` com `yes ""` ou script de input mockado
- Verifica que `agent-config.yml` gerado é YAML válido
- Não faz deploy real (sem credenciais)

### 11. Documentar sistema operacional suportado

README atual não diz explicitamente:
- **install.sh / setup.sh**: macOS, Debian/Ubuntu, RHEL (conforme plano)
- **Na VM**: Debian/Ubuntu (imagem Container-Optimized ou padrão GCE)

Adicionar seção "Supported platforms" no README.

### 12. Arquivo SECURITY.md

Conteúdo sugerido:

```markdown
# Security Policy

## Supported Versions
| Version | Supported          |
| ------- | ------------------ |
| 1.x.x   | :white_check_mark: |

## Reporting a Vulnerability
Email: [seu-email] or open a private security advisory on GitHub.
We aim to respond within 48 hours.
```

---

## 🟢 Boas práticas já alinhadas

- **MIT License**: Permissiva, ampla adoção
- **Estrutura clara**: lib/, providers/, templates/ bem separados
- **AGENTS.md/CLAUDE.md**: Instruções para AI assistants — diferencial
- **Templates .example**: Nunca commitam secrets
- **Documentação inline**: Scripts com cabeçalhos descritivos

---

## Checklist pré-lançamento

- [ ] Criar CONTRIBUTING.md
- [ ] Criar CODE_OF_CONDUCT.md (usar [Contributor Covenant](https://www.contributor-covenant.org/))
- [ ] Criar SECURITY.md
- [ ] Criar CHANGELOG.md com v1.0.0
- [ ] Adicionar issue templates (bug, feature, config)
- [ ] Adicionar PR template
- [ ] Corrigir ano no LICENSE
- [ ] Adicionar badges ao README
- [ ] Adicionar "Supported platforms" ao README
- [ ] Documentar "Verified install" alternativo
- [ ] Criar release v1.0.0 com SHA256SUMS
- [ ] (Opcional) Smoke-test no CI

---

## Resumo

O projeto está **bem estruturado** em termos de arquitetura, segurança e CI básico. As lacunas principais são **documentação de comunidade** (CONTRIBUTING, CODE_OF_CONDUCT, SECURITY) e **polish de release** (CHANGELOG, templates, badges). Implementar o checklist acima coloca o repo no nível de projetos open source maduros como create-react-app ou nvm.

**Prioridade alta**: CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, corrigir LICENSE, PR/Issue templates.
**Prioridade média**: CHANGELOG, badges, supported platforms, verified install.
**Prioridade baixa**: Smoke-test CI, assinatura de releases.
