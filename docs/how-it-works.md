# How it works

## Architecture

```mermaid
flowchart LR
    subgraph Clients
        UI[Browser UI]
        CL[API clients]
        AG[AI agent<br/>Claude · Copilot]
    end
    KONG[Kong<br/>access control]
    subgraph App["bwce-ai-generator-github (Flogo)"]
        REST["REST trigger :9999"]
        MCP["MCP server :8081"]
        FLOWS["Flows<br/>chat · extract · generate · tracker<br/>schemas · IKD · Kubernetes · code review"]
    end
    subgraph Services
        LLM["LLM, OpenAI-compatible<br/>(Ollama qwen2.5:7b)"]
        WV["Weaviate :18080<br/>template catalog"]
        PG[("PostgreSQL :5432<br/>registry · chat · IKD · reviews")]
        GH["GitHub<br/>template library · target repositories"]
        SMTP["SMTP<br/>(MailDev for development)"]
        K8S["Kubernetes API"]
        CR["Code review service"]
    end
    UI & CL --> KONG --> REST
    AG --> MCP
    REST & MCP --> FLOWS
    FLOWS --> LLM & WV & PG & GH & SMTP & K8S & CR
```

## Startup

When the app starts, `StartupFlow` prepares everything the request flows read, so no request reads a configuration
file or creates a table:

```mermaid
sequenceDiagram
    autonumber
    participant E as Flogo engine
    participant S as StartupFlow
    participant F as config files
    participant SD as Shared data
    participant PG as PostgreSQL
    participant WV as Weaviate
    E->>S: app start (startup hook)
    S->>F: read the template catalog, IKD id lists, operations programs
    S->>SD: APP_CONFIG (catalog), APP_IKD (ids), APP_OPS (jq programs), APP_K8S (contexts from K8S_CONTEXTS)
    S->>PG: create or upgrade the tables in one idempotent statement
    S->>WV: create the template collection if missing
    S->>WV: ingest the catalog (embeddings)
    S-->>E: log startup complete
```

## From conversation to repository

The typical journey in the web UI: the chat collects the integration spec turn by turn, then `POST /generate`
publishes the repository. API clients do the same with `POST /extract` (one shot) and `POST /generate`; AI agents use
the [MCP tools](mcp.md).

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant UI as Web UI
    participant CH as api_chat flows
    participant EX as ExtractSpecCore
    participant LLM as LLM
    participant PG as PostgreSQL
    participant SG as api_templates_suggest_POST
    participant WV as Weaviate
    participant GEN as generate_POST
    participant SC as ScaffoldArtifactsFlow
    participant GH as GitHub
    participant NT as SendNotificationFlow
    U->>UI: open the web UI
    UI->>CH: POST /api/chat/init
    CH->>PG: create the session (chat_session)
    CH-->>UI: session id and greeting
    loop until no required field is missing
        U->>UI: describe the integration
        UI->>CH: POST /api/chat/message
        CH->>PG: load the session spec
        CH->>EX: extract from the message
        EX->>EX: rule engine pre-extraction
        EX->>LLM: extraction prompt
        LLM-->>EX: JSON fields
        EX-->>CH: extracted fields
        CH->>CH: merge into the spec, list missing fields
        CH->>PG: save the session
        CH-->>UI: reply, spec, missing fields
    end
    opt suggest templates
        UI->>SG: POST /api/templates/suggest
        SG->>WV: hybrid search
        SG-->>UI: ranked templates
    end
    U->>UI: choose the publish target and generate
    UI->>GEN: POST /generate with spec and target_mode
    GEN->>GEN: validation rules and IKD check
    GEN->>PG: duplicate check
    GEN->>SG: template search, unless a template was requested
    SG->>WV: hybrid search
    GEN->>SC: scaffold
    SC->>GH: fetch the template at TEMPLATE_REF
    SC->>GH: one commit with code, configs and CI/CD files
    SC-->>GEN: GitHub URL and commit
    GEN->>PG: register the generation and its IKD ids
    GEN->>NT: notify
    NT->>NT: e-mail to the integration team (SMTP)
    GEN-->>UI: repository, GitHub URL and steps
```

## Generation gates

`POST /generate` (the UI's Generate step and the MCP tool `generate_code`) is a chain of gates; nothing is written
until every gate has passed.

```mermaid
flowchart TD
    N["DeriveNaming · NormalizeSpec<br/>repository name, defaults, target_mode"] --> V["ValidateSpec<br/>rule engine"]
    V -- "errors" --> R1["400 VALIDATION_FAILED"]
    V -- "valid" --> I["CrossCheckIKD"]
    I -- "unknown id" --> R2["400 IKD_VALIDATION_FAILED"]
    I -- "valid" --> D["CheckDuplicate<br/>generation_log"]
    D -- "registered, not config_only" --> R3["200 duplicate: true<br/>existing registration"]
    D -- "new, or config_only" --> T["SelectTemplate<br/>requested or hybrid search"]
    T --> S["ScaffoldArtifacts<br/>Git Repo Scaffolder: one commit"]
    S --> G["RegisterGeneration · RegisterIKD"] --> M["NotifyTeam<br/>e-mail"] --> OK["200 success"]
```

| Gate | Check | On failure |
|------|-------|------------|
| Validation | `rules/spec-validation.yaml`: required fields, repository name ≤ 50 characters, e-mail domain, … | 400 `VALIDATION_FAILED` with details, no writes |
| IKD | `interface_id` / `scenario_id` exist in the IKD lists | 400 `IKD_VALIDATION_FAILED` |
| Idempotency | no registration for the repository name yet (unless `config_only`) | 200 with the existing registration |
| Race safety | `UNIQUE(repo_name)` + `ON CONFLICT` | concurrent duplicates collapse to one row |

A runtime fault (for example PostgreSQL down) is caught by the flow's error handler: 500 `INTERNAL_ERROR` with the
failing activity and message.

**Repository name:** `[in<area>-]src-object-target[-uid][-country]-itype` (product-area prefix map,
`REST_SERVICE`/`SOAP_SERVICE` → `service`).
**Generated content:** `code/<repo>/…` (the template project with its tokens replaced and paths renamed),
`configs/generation.properties`, `configs/generation-metadata.json` and the CI/CD files `.github/workflows/ci.yml`,
`Jenkinsfile`, `k8s/deployment-<env>.yaml` and `config/runtime-<env>.json` (templates in `config/ops-programs.json`,
off with `GENERATE_CICD=false`). `config_only: true` refreshes only `configs/` and keeps the code.
**IKD registry:** every generation registers `<interface_id>:<repo>` / `<scenario_id>:<repo>` in `ikd_registry`
(replacing the repository's previous entry; skipped for config-only).

## Where the code is published

| `target_mode` | Result |
|---------------|--------|
| `subfolder` (default) | folder `<repo>/` in the shared repository `TARGET_REPO_URL`, branch `TARGET_BRANCH` |
| `newRepo` | new private repository `<repo>` under `TARGET_OWNER_URL` |

`TARGET_MODE` sets the default; a request overrides it with `target_mode` (REST `/generate`, MCP `generate_code`, UI).
The registry stores where each repository went, so links, duplicate answers, config-only refreshes, schema uploads and
cleanup keep following the repository when the default changes later.

The repository name is derived from the spec, so **the same spec maps to the same repository**: `/generate` answers
`duplicate: true` with the existing registration and changes nothing. In the UI, a new request after a generation
starts a new conversation.

**New repository from the UI:** describe the integration in the chat, choose **🆕 New repository** after the
product-area step (or type `/newrepo` at any time; `/shared` switches back), then generate; the result links the new
repository.

**Cleanup:** `DELETE /api/tracker/{repo_name}` (UI: `/cleanup <repo>` or **🧹 Clean up repository**) deletes the
folder from the shared repository in one commit and removes the registry and IKD rows. A repository of its own is kept
on GitHub (deleting a repository cannot be undone and needs extra token rights); delete it there by hand.

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant UI as Web UI
    participant CL as api_tracker_repo_DELETE
    participant PG as PostgreSQL
    participant GH as GitHub
    U->>UI: cleanup command or Clean up repository, then confirm
    UI->>CL: DELETE /api/tracker/repo_name
    CL->>PG: find the registration and where it was published
    alt folder of the shared repository
        CL->>GH: one commit that deletes the folder
        CL->>PG: delete the generation and IKD rows
        CL-->>UI: folder and rows removed
    else repository of its own
        CL->>PG: delete the generation and IKD rows
        CL-->>UI: rows removed, repository kept on GitHub
    end
```
