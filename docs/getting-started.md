# Getting started

## Prerequisites

| Component | Default | Notes |
|-----------|---------|-------|
| TIBCO Flogo CLI (`fcli`) | build context `flogo-studio-2268` (Flogo 2.26.8) | with the custom extensions from [flogo-custom-extensions](https://github.com/mpandav-tibco/flogo-custom-extensions): Git Repo Scaffolder, Rule Engine, Weaviate VectorDB connector; Go 1.26 or newer (with `GOTOOLCHAIN=auto`, Go fetches the 1.27.1 toolchain the runtime asks for) |
| PostgreSQL | `localhost:5432`, database `flogo_agent_studio`, user `flogo` | tables are created or upgraded at startup |
| Weaviate | `localhost:18080` | collection `BWCECiTemplates768`, filled from the catalog at startup |
| LLM and embeddings | Ollama at `localhost:11434` with `qwen2.5:7b` and `nomic-embed-text` | `ollama pull qwen2.5:7b`, `ollama pull nomic-embed-text`; any OpenAI-compatible endpoint works |
| GitHub token | environment variable `GITHUB_TOKEN` | Contents read/write on the template library and the target repository; `newRepo` also needs Administration read/write to create repositories |
| SMTP | `localhost:1025` | for development, MailDev: `docker run -d -p 1080:1080 -p 1025:1025 maildev/maildev:2.1.0`, inbox at http://localhost:1080 |
| Kubernetes API (optional) | `K8S_CONTEXTS` | for a local cluster, `kubectl proxy --port=8001` |
| Code review service (optional) | `CODE_REVIEW_BASE_URL` | until `CODE_REVIEW_USERNAME` and `CODE_REVIEW_PASSWORD` are set, the code review endpoints answer 503 |

## Build and run locally

```bash
# once: a build context from the Flogo 2.26.8 VS Code extension package and the custom extensions checkout
fcli create-context -n flogo-studio-2268 -v flogo-vscode-darwin-arm64-2.26.8-3377.vsix -u <path>/flogo-custom-extensions

fcli build-exe -f bwce-ai-generator-github.flogo -c flogo-studio-2268 -n bwce-ai-generator-github -o .
codesign --force --sign - ./bwce-ai-generator-github   # macOS only: ad-hoc signature, or the binary is killed at start
FLOGO_APP_PROPS_ENV=auto FLOGO_EXPOSE_SWAGGER_EP=true GITHUB_TOKEN=<token> ./bwce-ai-generator-github
```

Start it from the repository root: it reads `config/`, `rules/` and `static/` relative to the working directory.
With `FLOGO_APP_PROPS_ENV=auto`, every app property can be set with an environment variable (for example
`TARGET_MODE=newRepo`; see [Deploy in your environment](deployment.md)). UI: http://localhost:9999 ·
API definition: http://localhost:9999/api/v2/swagger.json (with `FLOGO_EXPOSE_SWAGGER_EP=true`) · MCP:
http://localhost:8081/mcp.

## Verify

```bash
curl -s http://localhost:9999/health
curl -s http://localhost:9999/api/templates | head -c 300
curl -s -X POST http://localhost:9999/generate -H 'Content-Type: application/json' \
  -d '{"spec":{"source_system":"S4HANA","target_system":"KAFKA","business_object":"Article","interface_type":"pub","product_area":"product_area-csddistribution","env":"DEV"}}'
curl -s -X DELETE http://localhost:9999/api/tracker/<repo_name>    # removes a test generation again
```
