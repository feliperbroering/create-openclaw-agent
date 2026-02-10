# Mem0 Memory Plugin — Setup Guide

How to install and configure the [Mem0](https://mem0.ai) persistent memory plugin on a self-hosted OpenClaw instance running in Docker.

Reference: [mem0.ai/blog/mem0-memory-for-openclaw](https://mem0.ai/blog/mem0-memory-for-openclaw)

## What Mem0 Does

OpenClaw agents are stateless between sessions. Mem0 adds persistent memory:

- **Auto-Capture**: after each agent turn, extracts facts and stores them (name, preferences, decisions, project context)
- **Auto-Recall**: before each agent turn, searches for relevant memories and injects them into context
- **5 tools** available to the agent: `memory_search`, `memory_store`, `memory_get`, `memory_list`, `memory_forget`

Memories survive context compaction, session restarts, and (with Qdrant vector store) container restarts.

## Installation

The OpenClaw CLI runs inside the Docker container. Install the plugin from npm:

```bash
docker exec <container> node dist/index.js plugins install @mem0/openclaw-mem0
```

This will:
- Download `@mem0/openclaw-mem0` from npm
- Install to `~/.openclaw/extensions/openclaw-mem0/`
- Disable the built-in memory plugins (`memory-core`, `memory-lancedb`)
- Set `openclaw-mem0` as the exclusive `memory` slot plugin

## Configuration

### 1. API Keys

The plugin needs the OpenAI API key passed as an environment variable to the Docker container (used for both LLM memory extraction and embeddings).

In your `.env` file (copy from `docker/.env.example`):
```bash
OPENAI_API_KEY=               # From platform.openai.com (for Mem0 LLM memory extraction and embeddings)
```

In your `docker-compose.override.yml` (copy from `docker/docker-compose.override.example.yml`):
```yaml
services:
  openclaw-gateway:
    environment:
      OPENAI_API_KEY: ${OPENAI_API_KEY}
```

### 2. Plugin Config in openclaw.json

Add this to `plugins.entries` in `openclaw.json`:

```json
"openclaw-mem0": {
  "enabled": true,
  "config": {
    "mode": "open-source",
    "userId": "your-user-id",
    "autoCapture": true,
    "autoRecall": true,
    "topK": 5,
    "searchThreshold": 0.5,
    "oss": {
      "llm": {
        "provider": "openai",
        "config": {
          "model": "gpt-4o-mini",
          "apiKey": "${OPENAI_API_KEY}"
        }
      },
      "embedder": {
        "provider": "openai",
        "config": {
          "model": "text-embedding-3-small",
          "apiKey": "${OPENAI_API_KEY}"
        }
      },
      "vectorStore": {
        "provider": "qdrant",
        "config": {
          "url": "http://localhost:6333",
          "collectionName": "openclaw_memories"
        }
      },
      "historyDbPath": "/home/node/.openclaw/memory/mem0-history.db"
    }
  }
}
```

### 3. Restart the gateway

```bash
docker compose down && docker compose up -d
```

The startup log should show:
```
openclaw-mem0: registered (mode: open-source, user: your-user-id, autoRecall: true, autoCapture: true)
openclaw-mem0: initialized (mode: open-source, user: your-user-id, autoRecall: true, autoCapture: true)
```

## Architecture Choices

### Why open-source mode (not platform)?

Platform mode (Mem0 Cloud) is simpler but sends all conversation data to Mem0's servers. Open-source mode keeps everything local on your VM.

### Why GPT-4o-mini for the LLM?

The Mem0 LLM extracts facts from conversations. Using a smaller, cheaper model like `gpt-4o-mini` is sufficient for memory extraction and avoids competing with the main agent for rate limits. GPT-4o-mini is cost-effective and provides good quality for fact extraction tasks.

**Important:** Check which models your API key has access to before configuring. Use:
```bash
docker exec <container> node -e "
const https = require('https');
const fs = require('fs');
const auth = JSON.parse(fs.readFileSync('/home/node/.openclaw/agents/main/agent/auth-profiles.json','utf8'));
const key = auth.profiles['openai:default'].key;
const req = https.request({
  hostname: 'api.openai.com', path: '/v1/models', method: 'GET',
  headers: { 'Authorization': 'Bearer ' + key }
}, res => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>{ const m=JSON.parse(d); console.log(m.data.filter(x=>x.id.startsWith('gpt')).map(x=>x.id).join('\n')); }); });
req.end();
"
```

### Why OpenAI for LLM and embeddings?

We use OpenAI for both the LLM (memory extraction) and embeddings (vector search). OpenAI's `text-embedding-3-small` is the cheapest embedding option (~$0.02 per 1M tokens) and is the default in the mem0ai SDK. Using the same provider simplifies API key management.

### Why Qdrant vector store?

The default vector store is in-memory — memories are lost on every container restart. Qdrant is a purpose-built vector database that runs as a Docker sidecar alongside the OpenClaw gateway:
- **Persistent local storage** — data lives at `~/.openclaw/memory/qdrant/` via volume mount, survives container and VM restarts
- **No external hosted service** — runs entirely on your VM, no data leaves your infrastructure
- **Scalable** — supports billions of vectors in production workloads
- **Fast** — native SIMD-accelerated similarity search
- **Automatically backed up** — the `memory/qdrant/` directory is included in GCS backups

The JavaScript mem0ai SDK requires a running Qdrant server (embedded/local mode is Python-only), which is why we run it as a sidecar container.

Supported vector store providers in mem0ai/oss (JavaScript): `memory`, `qdrant`, `redis`, `supabase`, `langchain`, `vectorize`, `azure-ai-search`.

### Why debounceMs: 3000?

With `debounceMs: 0`, every WhatsApp message triggers a separate agent turn. Rapid messages (3-4 in a row) cause multiple parallel API calls that blow through the 30k tokens/min rate limit. A 3-second debounce batches rapid messages into a single turn.

## Qdrant Sidecar Container

Qdrant runs as a Docker service alongside the OpenClaw gateway, defined in your `docker-compose.override.yml`:

```yaml
services:
  qdrant:
    image: qdrant/qdrant:v1.13.2
    network_mode: host
    volumes:
      - ${OPENCLAW_CONFIG_DIR}/memory/qdrant:/qdrant/storage
    deploy:
      resources:
        limits:
          cpus: "0.5"
          memory: 512M
    restart: unless-stopped
```

Key details:
- **`network_mode: host`** — both the gateway and Qdrant share the host network, so the gateway connects to Qdrant at `http://localhost:6333`
- **Volume mount** — `${OPENCLAW_CONFIG_DIR}/memory/qdrant:/qdrant/storage` persists all vector data at `~/.openclaw/memory/qdrant/` on the host
- **Resource limits** — 0.5 CPU and 512M memory are sufficient for single-user workloads
- **Backup coverage** — since the gateway volume-mounts the same `~/.openclaw/` directory, the existing backup script automatically includes Qdrant data

## Troubleshooting

### "capture failed: 404 model not found"

Two common causes:

1. **Model name has a provider prefix** — If the model is set to `openai/gpt-4o-mini` (with `openai/` prefix), the SDK passes the full string as the model name to the OpenAI API, which doesn't recognize it. Fix: use just the model ID without the provider prefix (e.g. `gpt-4o-mini`). The `provider` field already tells the SDK which API to call.

2. **Model not available for your API key** — List available models (see command above) and update `openclaw.json`.

### "capture failed: 429 rate_limit_error"

The Mem0 LLM is hitting the same rate limit as the main agent. Fix: use a different model for Mem0 (e.g. `gpt-4o-mini` instead of `gpt-4o` or `gpt-4-turbo`).

### "MissingEnvVarError: Missing env var"

The `${VAR_NAME}` syntax in `openclaw.json` requires the env var to be set and non-empty in the Docker container. Check your `docker-compose.override.yml` passes the variable, and your `.env` has a real value (not empty).

### Memories lost on restart

You're using the default in-memory vector store. Configure Qdrant (see config above) and ensure the Qdrant sidecar container is running.

## What Gets Backed Up

The backup script (`openclaw-backup.sh`) saves all Mem0 components for complete disaster recovery:

**Memory data:**
- `memory/qdrant/` — Qdrant vector store with all embeddings
- `memory/mem0-history.db` — conversation history for memory extraction (SQLite)
- `memory/main.sqlite` — OpenClaw's built-in memory search index

**Plugin installation:**
- `extensions/openclaw-mem0/` — the installed mem0 plugin code (ensures plugin is available after restore without manual reinstall)

**Configuration:**
- `openclaw.json` — plugin configuration (vectorStore, LLM, embedder settings)
- `.env` — API keys (OPENAI_API_KEY for mem0)
- `docker-compose.override.yml` — Qdrant sidecar container configuration

After restore, Mem0 will function immediately without requiring plugin reinstallation.
