# Relatório de Review — Plano `openclaw_setup_overhaul_73130a9b`

## Escopo

Review técnico do plano de reestruturação para transformar o projeto em uma CLI `create-openclaw-agent`, com foco em:

- segurança de secrets;
- resiliência operacional;
- riscos de regressão;
- completude de migração/restauração.

---

## Principais achados

### 1) Crítico — Contradição entre “zero plaintext em disco” e implementação proposta

**Evidência no plano**

- O plano define que todas as secrets devem ficar no Secret Manager com “zero plaintext em disco”.
- A seção de startup propõe gerar `.env` persistido com as chaves recuperadas do Secret Manager.

**Risco**

- Mantém superfície de vazamento local (filesystem, backup acidental, inspeção indevida, dump).
- Quebra o requisito de segurança declarado como pilar da nova arquitetura.

**Recomendação**

- Evitar persistência de secrets em arquivo.
- Injetar secrets somente em runtime (processo/memória) ou via mecanismo temporário com ciclo de vida curto.
- Se houver necessidade operacional de arquivo, documentar explicitamente a exceção e compensações (hardening, exclusão de backup, rotação agressiva, auditoria).

---

### 2) Alto — Healthchecks dependem de `curl` dentro de imagens sem garantia

**Evidência no plano**

- Healthchecks de gateway, qdrant e chrome usam `curl` nos comandos.

**Risco**

- Se a imagem não tiver `curl`, healthcheck falha permanentemente.
- Pode causar restart loop e indisponibilidade do serviço.

**Recomendação**

- Validar por imagem a ferramenta disponível (`curl`, `wget` etc.).
- Padronizar healthcheck compatível com cada container.
- Incluir teste de smoke pós-deploy validando estado saudável dos três serviços.

---

### 3) Alto — Fluxo de migração não especifica transporte seguro de secrets entre providers

**Evidência no plano**

- Migração cobre backup, provisionamento e restore.
- Não há etapa clara para reidratação de valores secretos no provider de destino.

**Risco**

- Restore incompleto em migração cross-cloud.
- Falha de inicialização por falta de chaves no backend de secrets alvo.

**Recomendação**

- Adicionar fase obrigatória “secrets migration/rehydration” no wizard.
- Exigir validação de presença/versão dos secrets antes de iniciar containers.
- Definir comportamento explícito para GCP→AWS/Azure (reentrada manual segura ou fluxo automatizado controlado).

---

### 4) Médio — Estratégia `curl | bash` sem pin de versão/hash

**Evidência no plano**

- Instalação via script remoto apontando para branch `main`.

**Risco**

- Vetor de supply-chain caso o conteúdo remoto seja alterado indevidamente.
- Dificulta reprodutibilidade.

**Recomendação**

- Preferir install por release versionada (tag imutável).
- Publicar checksum/assinatura do instalador.
- Expor modo “instalação segura” com verificação de integridade.

---

### 5) Médio — Falta plano de validação automatizada para refactor amplo

**Evidência no plano**

- Mudança estrutural significativa (novos scripts, provider interface, templates, onboarding).
- Sem matriz de testes/gates de qualidade explícita.

**Risco**

- Regressões silenciosas em setup, backup, restore e bootstrap da VM.

**Recomendação**

- Definir pipeline mínimo com:
  - lint de shell;
  - validação de Terraform/OpenTofu;
  - testes de smoke para `New Agent`, `Migrate` e `Restore`;
  - checklist de aceitação por cenário.

---

## Itens em aberto (decisões necessárias)

1. Como cumprir “zero plaintext em disco” sem sacrificar operação do runtime?
2. Qual estratégia oficial para migração de secrets entre clouds?
3. Qual política de release segura para o instalador (`install.sh`)?
4. Qual matriz mínima de testes para liberar a nova CLI?

---

## Conclusão

O plano está forte em visão e arquitetura, mas ainda tem lacunas relevantes em segurança e confiabilidade operacional.  
Antes de iniciar implementação ampla, recomenda-se resolver os três pontos críticos de execução: **segredo em disco**, **migração de secrets** e **gates de validação automatizada**.
