# Deploy in your environment

Every connection to infrastructure — GitHub, PostgreSQL, Weaviate, the LLM and embedding endpoints, the mail server,
Kubernetes and the code review service — is an app property, so the same `.flogo` runs against your systems without
changing a flow or an activity. With `FLOGO_APP_PROPS_ENV=auto` each property is read from an environment variable:
the property name in upper case with dots replaced by underscores (`PostgreSQL.GenerationRegistry.Host` →
`POSTGRESQL_GENERATIONREGISTRY_HOST`). A variable that is not set keeps the default built into the app.

| Your system | Environment variables |
|-------------|-----------------------|
| GitHub or GitHub Enterprise | `GITHUB_TOKEN`, `GITHUB_API_URL`, `TEMPLATE_REPO_URL`, `TEMPLATE_REF`, `TARGET_MODE`, `TARGET_REPO_URL`, `TARGET_OWNER_URL`, `TARGET_BRANCH`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` |
| PostgreSQL | `POSTGRESQL_GENERATIONREGISTRY_HOST`, `_PORT`, `_DATABASE_NAME`, `_USER`, `_PASSWORD`; TLS: `_TLS`, `_TLS_MODE` (`VerifyCA` or `VerifyFull`), `_CA_CERTIFICATE` (base64-encoded PEM) |
| Weaviate | `WEAVIATE_WEAVIATETEMPLATEKB_HOST`, `_PORT`, `_SCHEME` (`https` for TLS), `_API_KEY`; `VECTOR_COLLECTION` |
| LLM | `LLM_PROVIDER` (`Ollama`; `OpenAI`, `Azure OpenAI` or `Custom` for an OpenAI-compatible endpoint), `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY` |
| Embeddings | `LLM_EMBEDDING_PROVIDER`, `LLM_EMBEDDING_BASE_URL`, `LLM_EMBEDDING_MODEL`, `LLM_EMBEDDING_API_KEY`, `LLM_EMBEDDING_DIMENSIONS` |
| Mail server | `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURITY` (`NONE`, `TLS` for STARTTLS, `SSL`), `SMTP_USERNAME`, `SMTP_PASSWORD`, `NOTIFY_SENDER`, `NOTIFY_RECIPIENTS`, `NOTIFY_ORGANIZATION`; the e-mail text: [Notification e-mail](configuration.md#notification-e-mail) |
| Kubernetes (optional) | `K8S_CONTEXTS`, `K8S_CONTEXT`, `K8S_INSECURE`, `K8S_CA_CERT` |
| Code review (optional) | `CODE_REVIEW_BASE_URL`, `CODE_REVIEW_USERNAME`, `CODE_REVIEW_PASSWORD` and the other `CODE_REVIEW_*` settings |

[deploy/config.env.example](../deploy/config.env.example) lists every setting with its default and notes, and
[deploy/secrets.env.example](../deploy/secrets.env.example) the secrets. Copy them to `deploy/config.env` and
`deploy/secrets.env` (git ignores both) and fill them in.

**1. Build.** Linux executables and images are built with your licensed TIBCO Flogo tooling; the free VS Code edition
builds only for the local machine. On TIBCO Platform, deploy the `.flogo` there and set the same app properties in the
platform. For a container image:

```bash
mkdir -p build
fcli build-exe -f bwce-ai-generator-github.flogo -c <context> -p linux/amd64 -n bwce-ai-generator-github -o build
docker build -f deploy/Dockerfile -t <registry>/bwce-ai-generator:1.0.0 .
```

The image ([deploy/Dockerfile](../deploy/Dockerfile)) holds the executable with `config/`, `rules/` and `static/`, runs
as a non-root user and sets `FLOGO_APP_PROPS_ENV=auto` and `FLOGO_EXPOSE_SWAGGER_EP=true`.

**2. Run** with Docker:

```bash
docker run -d --name bwce-ai-generator -p 9999:9999 -p 8081:8081 \
  --env-file deploy/config.env --env-file deploy/secrets.env <registry>/bwce-ai-generator:1.0.0
```

or on Kubernetes ([deploy/kubernetes.yaml](../deploy/kubernetes.yaml): Deployment and Service; set the image first):

```bash
kubectl create namespace bwce-ai-generator
kubectl -n bwce-ai-generator create configmap bwce-ai-generator-config --from-env-file=deploy/config.env
kubectl -n bwce-ai-generator create secret generic bwce-ai-generator-secrets --from-env-file=deploy/secrets.env
kubectl -n bwce-ai-generator apply -f deploy/kubernetes.yaml
```

Expose port 9999 through Kong (see [Access control](#access-control-kong)).

**3. Check** `GET /health` and the log: at startup the app creates or upgrades its tables and ingests the template
catalog (`IngestDocuments: success … ingested=37`). PostgreSQL must be reachable at startup; the app does not start
without it. To use your own template catalog, IKD lists or e-mail templates without rebuilding the image, mount them over
`/app/config`.

When you change the embedding model, set `LLM_EMBEDDING_DIMENSIONS` to its vector size and use a new
`VECTOR_COLLECTION`: a collection keeps one vector size. The LLM and embedding requests do not go through an HTTP proxy
(`HTTPS_PROXY`), so those endpoints must be reachable directly.

## Access control (Kong)

The UI and the API are exposed through Kong, which authenticates and authorizes every request. The app trusts what
Kong forwards: it has no sign-in, accounts, sessions, roles or audit log, and neither the REST port (:9999) nor the
MCP server (:8081) checks credentials. Reach :9999 only through Kong, and keep :8081 internal or behind Kong as well.
To limit who may scale or restart deployments, switch the Kubernetes context or clean up repositories, restrict the
`POST /k8s/...` and `DELETE /api/tracker/...` routes in Kong (for example with the ACL plugin). A database created by
an earlier version still has the unused account and audit tables; drop them with
`DROP TABLE IF EXISTS public.app_user, public.login_attempt, public.audit_log;`.
