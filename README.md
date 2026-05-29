# BWCE AI Generator — Flogo Agentic AI

AI-powered accelerator that generates production-ready **TIBCO BWCE integration repositories** through natural language conversation, built on TIBCO Flogo Agentic AI.

## Overview

Migrated from a Python/FastAPI prototype to a native TIBCO Platform deployment using Flogo's agentic AI toolset. Supports conversational spec extraction, template selection via VectorDB RAG, and automated repo generation.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/api/templates` | List available BWCE templates |
| POST | `/api/chat/init` | Initialize a chat session |
| POST | `/api/chat/message` | Conversational spec extraction |
| POST | `/api/chat/reset` | Reset a session |
| POST | `/extract` | One-shot NLU extraction |
| POST | `/generate` | Generate BWCE repository |

## Architecture

- **Triggers**: TIBCO REST (tr_rest) + MCP Server for Claude/Copilot integration
- **AI**: TIBCO Flogo Agentic AI (agentactivity) + pongo2prompt templates
- **VectorDB**: Weaviate (template RAG search via ragQuery)
- **Storage**: PostgreSQL (generation registry) + Flogo SharedData (sessions)
- **Rules**: YAML-driven ruleengine for spec validation and alias normalization

## Flows

- `StartupFlow` — reads template registry, ingests to VectorDB, sets up DB
- `api_chat/*` — multi-turn conversational spec gathering
- `extract_POST` — one-shot NLU extraction with LLM
- `generate_POST` — validates spec, selects template, registers generation
- `MCPExtractSpecTool`, `MCPGenerateTool`, `MCPListTemplates` — MCP tools

## Prerequisites

- TIBCO Flogo 2.26.3+
- Weaviate (local: `http://localhost:8080`)
- PostgreSQL (database: `agentforge`)
- Ollama or OpenAI-compatible LLM endpoint

## Build

```bash
flogobuild build-exe -f bwce-ai-generator.flogo -c flogo-v2263-2498 -o ./bin/
```

## Run

```bash
./bin/bwce-ai-generator.exe
# API available at http://localhost:9999
# MCP server at http://localhost:8081
```

## Configuration

App properties (configure via Flogo app properties or environment):

| Property | Description | Default |
|----------|-------------|---------|
| `LLM_MODEL` | LLM model name | `llama3.1:8b` |
| `VECTOR_COLLECTION` | Weaviate collection | `BWCETemplates` |
| `RULES_PATH` | Rules directory | `rules/` |
| `TEMPLATE_REGISTRY` | Template list file | `config/templates.json` |
| `ALIAS_MAPPINGS` | Alias mappings file | `config/alias-mappings.json` |

## Test

```bash
bash test/api-test.sh
```
