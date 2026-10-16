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
        RULES["Rule Engine #ruleengine<br/>deterministic pre-extract (YAML)"]
        RAG["#ragQuery (vectordb-weaviate)<br/>vector search + LLM call"]
    end

    subgraph Deps["External services"]
        LLM["LLM provider<br/>(OpenAI-compatible:<br/>Ollama · vLLM · cloud)"]
        WV["Weaviate VectorDB<br/>:18080"]
        PG[("PostgreSQL :5432<br/>generation_log · chat_session")]
        SMTP["SMTP server<br/>(any relay; MailDev for dev)"]
        FS[["generated-repos/"]]
    end

    U --> REST
    AG --> MCP
    REST --> EX & CHAT & GEN
    MCP --> EX & GEN
    EX & CHAT --> RULES --> RAG
    RAG --> WV
    RAG --> LLM
    CHAT --> PG
    START --> WV
    GEN --> WV
    GEN --> PG
    GEN --> FS
    GEN --> SMTP
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
    participant M as SMTP server

    C->>G: POST /generate { spec }
    G->>G: NormalizeSpec
    G->>G: ValidateSpec
    alt spec invalid
        G-->>C: 400 VALIDATION_ERROR
    else spec valid
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
                G->>DB: RegisterGeneration (ON CONFLICT DO NOTHING) → GENERATED
                G->>FS: ScaffoldArtifacts → manifest.json + Dockerfile + k8s + README + pipeline
                G->>M: SendNotification email
                G-->>C: 200 { success:true, repo_name, generation_id }
            end
        end
    end
```

#### Governance gates (decision flow)

The pipeline is a chain of conditional gates — each either lets the request proceed or short-circuits to a reply, so **no side effect happens until every gate passes**:

```mermaid
flowchart TD
    N["NormalizeSpec<br/>alias canon · length cap · defaults"] --> V["ValidateSpec (#ruleengine)"]
    V -- "errorCount &gt; 0" --> R400["HTTP 400<br/>VALIDATION_ERROR"]
    V -- "errorCount == 0" --> IKD["CrossCheckIKD"]
    IKD -- "ikd_valid == false" --> R2A["HTTP 200<br/>IKD_VALIDATION_FAILED"]
    IKD -- "ikd_valid == true" --> DUP["CheckDuplicate (#query)"]
    DUP -- "rows &gt; 0 AND not config_only" --> R2B["HTTP 200<br/>duplicate · existing record"]
    DUP -- "rows == 0 OR config_only" --> RAG["SelectTemplate (RAG)"]
    RAG --> REG["RegisterGeneration<br/>#insert · ON CONFLICT (repo_name)"]
    REG --> SC["ScaffoldArtifacts"] --> NT["NotifyTeam"] --> OK["HTTP 200<br/>success"]
```

| Gate | Check | On fail |
|------|-------|---------|
| **Validation** | `ValidateSpec.errorCount == 0` (rule pack) | **400** `VALIDATION_ERROR` — fail fast, no writes |
| **IKD cross-check** | `ikd_valid == true` | **200** `IKD_VALIDATION_FAILED` |
| **Idempotency** | no existing `repo_name` *(unless `config_only`)* | **200** returns the existing record |
| **Race-safety** | `UNIQUE(repo_name)` + `ON CONFLICT DO NOTHING` | concurrent duplicates collapse to 1 row |

> Any runtime fault (e.g. PostgreSQL down) is caught by a flow-level error handler → structured **500** `{error, activity, code}`.

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET  | `/` | Web chat UI |
| GET  | `/health` | Health check |
| GET  | `/docs` | Interactive API reference |
| GET  | `/openapi.json` | OpenAPI 3.0 spec |
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
| `StartupFlow` | Loads the template registry + IKD ids, ingests templates into Weaviate, initializes the PostgreSQL `generation_log` + `chat_session` tables |
| `api_chat/*` | Multi-turn conversational spec gathering (session state persisted in PostgreSQL `chat_session`) |
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
| **SMTP server** | any relay | 1025 | **MailDev** is the local-dev default (mock SMTP + web inbox at :1080); point `SMTP_HOST`/`SMTP_PORT` at any relay |
| **LLM provider** | any OpenAI-compatible API | 11434 | **Ollama** is the local-dev default (`llama3.1:8b`, `nomic-embed-text`); swap in vLLM, LM Studio, or a cloud LLM |

> **Pluggable backends:** the LLM and the SMTP relay are *not* hard-wired — Ollama and MailDev are only the
> local-dev defaults. Point `LLM_Base_URL` at any OpenAI-compatible endpoint and `SMTP_HOST`/`SMTP_PORT` at any
> SMTP server; nothing else changes.

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
| `AgenticAI.LLMProvider.LLM_Base_URL` | LLM endpoint — any OpenAI-compatible API (Ollama / vLLM / cloud) | `http://localhost:11434` |
| `LLM_MODEL` | LLM model name (provider-specific) | `llama3.1:8b` |
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

---

## GitHub edition (`bwce-ai-generator-github.flogo`)

A second app generated from this one that produces the **real BWCE code** from the customer template library
(`ci-bwcetemplates`) and publishes it to GitHub in a single commit, using the
[Git Repo Scaffolder](https://github.com/mpandav-tibco/flogo-custom-extensions/tree/main/activity/gitreposcaffolder)
activity. Its output is byte-identical to the reference Python generator for the same template revision and spec.

| Aspect | Behaviour |
|--------|-----------|
| Repository name | `[in<area>-]src-object-target[-uid][-country]-itype`, product-area prefix map and `REST_SERVICE`/`SOAP_SERVICE` → `service`, max 50 chars (400 otherwise) |
| Template selection | Requested template if it exists in the catalog, otherwise Weaviate **hybrid** (BM25 + vector, α 0.25) over the 37-template catalog; the chat transcript is passed as `context` so transport hints ("from SFTP") count |
| Output layout | `<TARGET_REPO_URL>/<repo>/code/<repo>/…` + `<repo>/configs/generation.properties`, `generation-metadata.json` + CI/CD files (below) |
| Target modes | `TARGET_MODE=subfolder` (one shared repo, default) or `newRepo` (one repository per integration under `TARGET_OWNER_URL`) |
| Config-only | `config_only:true` refreshes only `configs/` and keeps the code |
| Extra endpoints | `GET /api/tracker` (registry rows with GitHub links), `POST /api/templates/suggest` (ranked templates) |
| CI/CD files | `.github/workflows/ci.yml`, `Jenkinsfile`, `k8s/deployment-<env>.yaml`, `config/runtime-<env>.json` — byte-identical to the reference `CICDScaffolder`; templates live in `config/ops-programs.json` (`cicd.templates`), off with `GENERATE_CICD=false` |
| IKD registry | Every generation registers `<interface_id>:<repo>` / `<scenario_id>:<repo>` (replacing the repo's previous entry, skipped for config-only) in `ikd_registry`; `GET /api/ikd?kind=InterfaceIDs\|ScenarioIDs` returns the reference `IKD_*.txt` content |
| UI | `static/chat-github.html` — chat, templates, tracker + schema upload, Kubernetes and code review tabs |
| Access control | Done by Kong in front of the app; the app has no sign-in, accounts, roles or audit log (see below) |

### Operations (ported from the reference generator)

All logic is Flogo flows; data-shaped logic (Kubernetes response mapping, request planning, CI/CD rendering) runs
as **jq programs** (TIBCO `json.jq`) loaded at startup from `config/ops-programs.json` into shared data, so one
generic flow serves many endpoints. Only OOTB activities are used (REST Invoke, PostgreSQL, Shared Data,
XML-to-JSON, Mapper) plus the Git Repo Scaffolder. Outbound HTTP goes through two subflows built from the OOTB
**Invoke REST Service** activity, one per target system:

| Subflow | Invokes (method, timeout) | TLS |
|---------|---------------------------|-----|
| `K8sRequest` | `Get` (GET, 30 s), `Patch` (PATCH merge patch, 30 s) | `K8S_INSECURE`, `K8S_CA_CERT` |
| `CodeReviewRequest` | `Probe` (GET, 6 s), `Get` (GET, 25 s), `PostForm` (form POST, 25 s), `PostJson` (JSON POST, 120 s) | `CODE_REVIEW_INSECURE` |

Method, request type and timeout are fixed per Invoke (the designer only offers them as literals), so the subflow
picks the Invoke from its inputs. The Settings URL is the default endpoint; the URL planned at runtime (path and
query) is mapped to the Invoke's `serviceUrl` input, which overrides it. A transport failure (DNS, TCP, TLS,
timeout) takes the error link to `Failed`, so both subflows always return `status`, `text`, `json`,
`content_type`, `elapsed_ms` and `error` (status 0 on a transport failure).

| Area | Endpoints | Notes |
|------|-----------|-------|
| Kubernetes | `GET /k8s/{resource}` (health, context, status, deployments, pods, services, events), `GET /k8s/{resource}/{name}`, `GET /k8s/{resource}/{name}/{view}` (rollout, logs, port-forward), `POST /k8s/deployments/{name}/{action}` (scale, restart), `POST /k8s/context/switch` | Same URLs as the reference; the route selects the operation (`k8s.routes` in `config/ops-programs.json`, anything else is 404). Calls the Kubernetes REST API directly (no kubectl) with the response shapes of the reference; contexts from `K8S_CONTEXTS` (JSON: url, namespace, token; TLS for all contexts from `K8S_INSECURE` and `K8S_CA_CERT`); restrict the `POST` routes (scale, restart, switch) in Kong if only operators may use them |
| Code review | `POST /api/codereview/token`, `POST /api/codereview/run`, `GET /api/codereview/history`, `GET /api/codereview/network-debug` | intginvent token cached in shared data, one retry with a refreshed token, history (newest 500) in PostgreSQL, report links extracted and query strings redacted |
| Schemas | `POST /api/schemas/upload/{kind}` (source, target, batch) | JSON body (`repository_name`, `filename`, `content` / `source_schemas[]`, `target_schemas[]`); XML is validated, files are committed into `<repo>.module/Schemas` or `Service Descriptors` in one commit, a source XSD gets the reference `adidasIntegrationMessage.xsd` wrapper |

Flow structure (Flogo designer): every REST handler is an operation of the embedded API definition
`specs/bwce-ai-generator-github-api.yaml` (also served as `/openapi.json`, rendered by `/docs`), one handler per
flow, named after the flow. Each handler maps the request (`pathParams`, `queryParams`, `body`) to the inputs the
flow declares and the flow's `code` + `responseBody` outputs to the reply. `root_GET`, `docs_GET` and
`openapi_json_GET` read their file and return it; the five Kubernetes endpoints are thin flows over `K8sOperation`.
Shared subflows: `CodeReviewToken`, `RecordCodeReview`, `ExtractSpecCore`, `K8sRequest`, `CodeReviewRequest`;
`/generate` reuses the
`/api/templates/suggest` flow for its template search, so the UI's "best match" is the template it generates.
Startup loads the local configuration first (template registry, IKD ids, operations programs, Kubernetes contexts),
then creates or upgrades the PostgreSQL tables in one idempotent statement, then ingests the templates into Weaviate.
To add an endpoint, add the operation to the API definition first (the designer offers Method/Path from it), then
its flow and handler.

Consolidation in this edition: the extraction pipeline duplicated in `/extract` and the chat is one
`ExtractSpecCore` subflow; the Return/Reply pairs of `/generate` and `/extract` are one Return each (the MCP tools
read `responseBody.body`); the pass-through `BuildRepoName` task, the unused `GetAppConfig` lookup, three unused
properties, duplicate import aliases, the never-bound `LLMProvider` connection and the unused File Write import
were removed. With access control in Kong, the in-app authentication went too: the login, session, user,
audit-log and diagnostics endpoints, the `AuthGuard`, `WriteAudit` and `StaticFile` subflows, the guard and audit
steps in every flow, the JWT import, the auth properties, the MCP server token, the alias mappings loaded at
startup but never read, and flow inputs nothing used (47 → 36 flows, 31 → 23 endpoints, 71 → 58 properties).
A second review merged `SetupDatabaseFlow` and `TemplateIngestionFlow` into `StartupFlow`, made `/generate` reuse the
suggest search, stored the IKD ids under one key, folded the error-body mappers into the error Returns and dropped
request logs the REST trigger already writes; the generic `HttpCall` subflow became the two OOTB REST subflows above
(36 → 35 flows, 245 → 229 activities, 58 → 59 properties).

Designer validation: the designer's **Validate** reports no errors in any flow. It resolves every mapped path
against declared schemas and checks each expression's result type, so: the request-body flow inputs (`content`,
the MCP tools' `arguments`) carry the API definition's schema; the `APP_OPS` shared data declares every program
key; query activities list their output columns; `json.jq`/`array.get` results are wrapped in
`coerce.toArray`/`coerce.toString` where the target is typed; link conditions avoid a leading `!(`, which the
designer's expression parser rejects; error branches read `$error[<activity>]`. Each flow's `metadata.fe_metadata`
matches its inputs and outputs (a stale copy made the designer rewrite flow inputs on save). The committed file is
the designer's own saved form, so opening it does not rewrite it.

Build and run:

```bash
fcli build-exe -f bwce-ai-generator-github.flogo -c flogo-studio-2265 -n bwce-ai-generator-github -o .
FLOGO_APP_PROPS_ENV=auto GITHUB_TOKEN=<fine-grained PAT: contents rw> ./bwce-ai-generator-github
bash test/e2e-github.sh    # 15 end-to-end checks (writes one folder to the target repo)
bash test/e2e-ops.sh       # Kubernetes, code review, schemas, IKD (optional: E2E_REPO=<repo> K8S_DEPLOYMENT=<name>)
```

`bwce-ai-generator-github.flogo` is maintained directly (Flogo designer / FDA); it is the source of truth. When the
API changes, edit `specs/bwce-ai-generator-github-api.yaml`, regenerate `static/openapi-github.json`
(`python3 -c 'import json,sys,yaml; json.dump(yaml.safe_load(open(sys.argv[1])), open(sys.argv[2],"w"), indent=2)'
specs/bwce-ai-generator-github-api.yaml static/openapi-github.json`) and load that JSON as the REST trigger's API spec.

Key properties: `GITHUB_TOKEN` (env only, never stored), `TEMPLATE_REPO_URL`, `TEMPLATE_REF`, `TARGET_MODE`,
`TARGET_REPO_URL`, `TARGET_OWNER_URL`, `TARGET_BRANCH`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
`TEMPLATE_REGISTRY=config/ci-bwcetemplates.json`, `VECTOR_COLLECTION=BWCECiTemplates768`.
Operations: `K8S_CONTEXTS`, `K8S_CONTEXT`, `K8S_INSECURE` (`false`), `K8S_CA_CERT` (PEM, base64 PEM or
`file:///var/run/secrets/kubernetes.io/serviceaccount/ca.crt`; empty = system CAs), `CODE_REVIEW_BASE_URL`,
`CODE_REVIEW_USERNAME`/`_PASSWORD`/`_USERID`/`_USERTYPE`/`_COOKIE`, `CODE_REVIEW_INSECURE` (`true` = no certificate
check, the reference default; it replaces the reference's `CODE_REVIEW_VERIFY_SSL` because the REST Invoke binds
"Disable SSL Verification" to a property, not an expression),
`CODE_REVIEW_TOKEN_METHOD` (`POST`; `GET` matches the reference but puts the password in the URL, and the REST
Invoke logs request URLs at INFO),
`OPS_PROGRAMS=config/ops-programs.json`, `GENERATE_CICD`. Secrets belong in the environment, not in the `.flogo`.

Differences from the reference: sign-in, accounts, roles and the audit log (Entra ID SSO included) are left to Kong;
the code review network check infers DNS/TCP/TLS from one HTTP probe; rollout status is a snapshot (no blocking
wait); schema upload takes JSON instead of multipart and requires a previously generated repository (404 otherwise).

### Access control (Kong)

The UI and the API are exposed through Kong, which authenticates and authorizes every request. The app trusts what
Kong forwards: it has no sign-in, accounts, sessions, roles or audit log, and neither the REST port (:9999) nor the
MCP server (:8081) checks credentials. Reach :9999 only through Kong, and keep :8081 internal or behind Kong as well.
To limit who may scale or restart deployments or switch the Kubernetes context, restrict the `POST /k8s/...` routes
in Kong (for example with the ACL plugin). A database created by an earlier version still has the unused account and
audit tables; drop them with `DROP TABLE IF EXISTS public.app_user, public.login_attempt, public.audit_log;`.
