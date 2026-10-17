# BWCE AI Generator (TIBCO Flogo)

Generates **TIBCO BusinessWorks Container Edition (BWCE) integration repositories** from plain-English requirements
and publishes them to GitHub. The app is a TIBCO Flogo application, `bwce-ai-generator-github.flogo`: it extracts a
structured integration spec with an LLM, picks the best template of the BWCE template library (`ci-bwcetemplates`,
37 templates) with Weaviate hybrid search, materializes the real project code and publishes it in a single commit.
For the same template revision and spec, its output is byte-identical to the reference Python generator.

It serves a web UI, a REST API (`:9999`) and an MCP server (`:8081`), plus the operations around generated
repositories: generation registry and cleanup, IKD registry, schema upload, Kubernetes status and actions, and code review.

---

## Highlights

- **Conversational or one-shot spec extraction** — a YAML rule engine pre-extracts high-confidence fields, the LLM
  fills in the rest; the chat keeps the spec across turns.
- **Governed generation** — validation rules, the IKD cross-check and duplicate detection run before anything is written.
- **Template selection** — the requested template if it is in the catalog, otherwise Weaviate **hybrid** search
  (BM25 + vector, α 0.25); the chat transcript is passed as context, so hints like "from SFTP" count.
- **Real code in one commit** — the [Git Repo Scaffolder](https://github.com/mpandav-tibco/flogo-custom-extensions/tree/main/activity/gitreposcaffolder)
  activity fetches the template, replaces its tokens, renames paths, adds configuration and CI/CD files and pushes
  one commit: into a folder of a shared repository, or into a new repository per integration.
- **Registry** — every generation is recorded in PostgreSQL together with where it was published; the same spec
  returns the existing registration, and a cleanup endpoint removes a generation again.
- **Operations** — Kubernetes (status, rollout, logs, scale, restart, context switch), code review, XSD/WSDL/OpenAPI schema
  upload, IKD export and a notification e-mail per generation.
- **Three front doors** — web UI, REST API (its OpenAPI definition served by Flogo) and an MCP server that offers
  every feature as a tool, so AI agents can do what a user can.

---

## Quick start

It needs PostgreSQL, Weaviate, an OpenAI-compatible LLM (for example Ollama) and a GitHub token; the
[prerequisites](docs/getting-started.md#prerequisites) list the defaults.

```bash
fcli build-exe -f bwce-ai-generator-github.flogo -c flogo-studio-2268 -n bwce-ai-generator-github -o .
codesign --force --sign - ./bwce-ai-generator-github   # macOS only
FLOGO_APP_PROPS_ENV=auto FLOGO_EXPOSE_SWAGGER_EP=true GITHUB_TOKEN=<token> ./bwce-ai-generator-github
```

Then open the web UI at http://localhost:9999 or connect an MCP client to http://localhost:8081/mcp.
[Getting started](docs/getting-started.md) covers the build context and a first generation;
[Deploy in your environment](docs/deployment.md) runs the app against your own systems.

---

## Documentation

| Guide | Contents |
|-------|----------|
| [Getting started](docs/getting-started.md) | prerequisites, build and run locally, verify |
| [How it works](docs/how-it-works.md) | architecture, startup, from conversation to repository, generation gates, where the code is published, cleanup |
| [Flows](docs/flows.md) | the 48 flows, what starts each one and what it does |
| [Web UI](docs/web-ui.md) | chat and commands, generated repositories, code review, Kubernetes |
| [REST API](docs/rest-api.md) | operations and the OpenAPI definition |
| [MCP server](docs/mcp.md) | client setup and the 17 tools |
| [Operations](docs/operations.md) | Kubernetes, code review and schema upload: endpoints and sequences |
| [Logging](docs/logging.md) | what each flow logs, following one request, log level and JSON format |
| [Deploy in your environment](docs/deployment.md) | environment variables, image, Docker, Kubernetes, access control with Kong |
| [Configuration](docs/configuration.md) | app properties and the notification e-mail |
| [Development](docs/development.md) | changing the app, designer rules, repository layout, differences from the reference generator |
