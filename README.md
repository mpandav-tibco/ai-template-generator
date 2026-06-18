# BWCE AI Generator — Flogo Agentic AI

AI-powered accelerator that generates production-ready **TIBCO BWCE integration repositories** from plain-English requirements, built entirely on **TIBCO Flogo Agentic AI**.

It combines a deterministic rule engine, an LLM for natural-language understanding, Weaviate vector search for template selection, and PostgreSQL for an idempotent generation registry — exposed over both a REST API and an MCP server.

---

## Highlights

- **Conversational & one-shot spec extraction** — describe an integration in English; the system extracts a structured BWCE spec.
- **Deterministic pre-extraction** — a YAML rule engine pulls high-confidence signals (IKD ids, systems, env) before the LLM runs, improving accuracy and making small local models viable.
- **Fence-tolerant JSON parsing** — LLM responses wrapped in prose / ```code fences``` are sanitized before parsing, so models like `llama3.1:8b` work reliably.
- **IKD cross-check** — `interface_id` / `scenario_id` are validated against the IKD registry before anything is generated.
- **Template RAG** — the best-matching template is selected via Weaviate vector search.
- **Idempotent generation** — duplicate specs return the existing record instead of re-scaffolding.
- **Repo scaffolding** + **notification email** on success.
- **Dual interface** — REST API (`:9999`) and MCP server (`:8081`) for Claude / Copilot agents.

---

## Architecture

```mermaid
flowchart LR
    subgraph Clients
        U[Developer / UI]
        AG[AI Agent<br/>Claude · Copilot]
    end

    subgraph App["BWCE AI Generator (Flogo)"]
        direction TB
        REST["REST Trigger :9999"]
        MCP["MCP Server :8081"]
        subgraph Flows
            EX["extract_POST<br/>one-shot NLU"]
            CHAT["api_chat/*<br/>multi-turn"]
            GEN["generate_POST<br/>pipeline"]
            START["StartupFlow<br/>ingestion"]
        end
        RULES["Rule Engine<br/>YAML"]
        PROMPT["pongo2prompt<br/>templates"]
        AGENT["agentactivity<br/>LLM"]
    end

    subgraph Deps["External services"]
        OLL["Ollama LLM<br/>:11434"]
        WV["Weaviate VectorDB<br/>:18080"]
        PG[("PostgreSQL<br/>generation_log :5432")]
        MAIL["MailDev SMTP<br/>:1025 / UI :1080"]
        FS[["generated-repos/"]]
    end

    U --> REST
    AG --> MCP
    REST --> EX & CHAT & GEN
    MCP --> EX & GEN
    EX & CHAT --> RULES --> PROMPT --> AGENT --> OLL
    START --> WV
    GEN --> WV
    GEN --> PG
    GEN --> FS
    GEN --> MAIL
```

### `generate_POST` pipeline (the headline flow)

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant G as generate_POST
    participant IKD as IKD Registry
    participant DB as PostgreSQL
    participant WV as Weaviate
    participant FS as Filesystem
    participant M as MailDev

    C->>G: POST /generate { spec }
    G->>G: ValidateSpec
    G->>IKD: CrossCheckIKD
    alt IKD invalid
        G-->>C: 200 IKD_VALIDATION_FAILED
    else IKD valid
        G->>G: BuildRepoName
        G->>DB: CheckDuplicate
        alt duplicate exists
            G-->>C: 200 { duplicate:true, existing record }
        else new
            G->>WV: SelectTemplate (RAG)
            G->>DB: RegisterGeneration → status GENERATED
            G->>FS: ScaffoldRepo → manifest.json
            G->>M: SendNotification email
            G-->>C: 200 { success:true, repo_name, generation_id }
        end
    end
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET  | `/health` | Health check |
| GET  | `/api/templates` | List available BWCE templates |
| POST | `/api/chat/init` | Initialize a chat session |
| POST | `/api/chat/message` | Conversational spec extraction |
| POST | `/api/chat/reset` | Reset a session |
| POST | `/extract` | One-shot NLU extraction |
| POST | `/generate` | Generate a BWCE repository |

MCP tools (`:8081`): `extract_spec`, `generate_code`, `list_templates`.

---

## Flows

| Flow | Purpose |
|------|---------|
| `StartupFlow` | Loads the template registry + IKD ids, ingests templates into Weaviate, initializes the PostgreSQL `generation_log` table |
| `api_chat/*` | Multi-turn conversational spec gathering (session state in Flogo SharedData) |
| `extract_POST` | One-shot NLU extraction (deterministic pre-extract + LLM) |
| `generate_POST` | Validate → IKD cross-check → template RAG → register → scaffold → notify |
| `MCPExtractSpecTool`, `MCPGenerateTool`, `MCPListTemplates` | MCP-exposed tools |

---

## Prerequisites

| Service | Where | Port | Notes |
|---------|-------|------|-------|
| TIBCO Flogo CLI (`fcli`) | host | — | build context `flogo-studio-2264` (2.26.4) |
| PostgreSQL | container `flogo-studio-postgres` | 5432 | db `flogo_agent_studio`, user `flogo` |
| Weaviate | container `weaviate` | 18080 | template RAG collection `BWCETemplates768` |
| MailDev | `docker-compose.maildev.yml` | 1025 / 1080 | mock SMTP relay + web inbox |
| Ollama | host | 11434 | models `llama3.1:8b`, `nomic-embed-text` |

---

## Quick start (demo)

Two helper scripts under [`demo/`](demo/) bring everything up and walk through the solution.

```bash
# 1. Start every prerequisite (Postgres, Weaviate, MailDev, Ollama) + the app.
#    Add --build to compile the binary first.
./demo/start-demo.sh            # or: ./demo/start-demo.sh --build

# 2. Run the guided, narrated walkthrough (pauses before each step).
./demo/run-demo.sh              # or: ./demo/run-demo.sh --auto

# Stop the app + MailDev when finished (shared services stay up).
./demo/start-demo.sh --stop
```

Once running:

- REST API → http://localhost:9999
- MCP server → http://localhost:8081
- MailDev inbox → http://localhost:1080
- App log → `/tmp/bwce-ai-generator.log`

---

## Build (manual)

```bash
fcli build-exe -f bwce-ai-generator.flogo -c flogo-studio-2264 -n bwce-ai-generator -o .
```

## Run (manual)

```bash
./bwce-ai-generator
# REST API on :9999, MCP server on :8081
```

---

## Configuration

App properties (set via Flogo app properties or environment overrides):

| Property | Description | Default |
|----------|-------------|---------|
| `AgenticAI.LLMProvider.LLM_Base_URL` | LLM endpoint | `http://localhost:11434` |
| `LLM_MODEL` | LLM model name | `llama3.1:8b` |
| `LLM_EMBEDDING_MODEL` | Embedding model | `nomic-embed-text` |
| `VECTOR_COLLECTION` | Weaviate collection | `BWCETemplates768` |
| `RULES_PATH` | Rules directory | `rules/` |
| `TEMPLATE_REGISTRY` | Template list file | `config/templates.json` |
| `SMTP_HOST` / `SMTP_PORT` | Notification relay | `localhost` / `1025` |
| `NOTIFY_SENDER` / `NOTIFY_RECIPIENTS` | Email from / to | `bwce-generator@adidas.com` / `core-integration@adidas.com` |
| `SCAFFOLD_OUTPUT_DIR` | Scaffold output | `generated-repos` |
| `PostgreSQL.GenerationRegistry.Database_Name` | Registry DB | `flogo_agent_studio` |

---

## Test

```bash
# Full REST API test suite (assumes the app is already running on :9999)
bash test/api-test.sh
```

The `generation_log` registry can be reset between demos with:

```bash
docker exec flogo-studio-postgres psql -U flogo -d flogo_agent_studio -c 'TRUNCATE generation_log;'
```
