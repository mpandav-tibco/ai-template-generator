# Configuration

| Area | App properties (default) |
|------|--------------------------|
| Publishing | `TARGET_MODE` (`subfolder`), `TARGET_REPO_URL`, `TARGET_BRANCH` (`main`), `TARGET_OWNER_URL`, `TEMPLATE_REPO_URL`, `TEMPLATE_REF` (`main`), `GITHUB_TOKEN` (environment only), `GITHUB_API_URL`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GENERATE_CICD` (`true`) |
| LLM and search | `LLM_PROVIDER` (`Ollama`), `LLM_BASE_URL`, `LLM_MODEL` (`qwen2.5:7b`), `LLM_API_KEY`, `LLM_EMBEDDING_PROVIDER` (`OpenAI`), `LLM_EMBEDDING_BASE_URL`, `LLM_EMBEDDING_MODEL` (`nomic-embed-text`), `LLM_EMBEDDING_API_KEY`, `LLM_EMBEDDING_DIMENSIONS` (`768`), `EXTRACTION_SYSTEM_PROMPT`, `VECTOR_COLLECTION` (`BWCECiTemplates768`), `weaviate.WeaviateTemplateKB.*` (connection, including `Scheme`) |
| Registry | `PostgreSQL.GenerationRegistry.*` (host, port, database, user, password, pool, `TLS`, `TLS_Mode`, `CA_Certificate`) |
| Files | `TEMPLATE_REGISTRY` (`config/ci-bwcetemplates.json`), `RULES_PATH` (`rules/`), `IKD_INTERFACES_FILE`, `IKD_SCENARIOS_FILE` (`config/ikd/…`), `OPS_PROGRAMS` (`config/ops-programs.json`), `BRAND_LOGO_FILE` |
| Notification | `SMTP_HOST` (`localhost`), `SMTP_PORT` (`1025`), `SMTP_SECURITY` (`NONE`), `SMTP_USERNAME`, `SMTP_PASSWORD`, `NOTIFY_SENDER` (`bwce-ai-generator@example.com`), `NOTIFY_RECIPIENTS` (`integration-team@example.com`), `NOTIFY_ORGANIZATION` (`Integration Platform`), `NOTIFY_TEMPLATE` (`config/email/new-repository.html`), `NOTIFY_TEMPLATE_CONFIG_ONLY` (`config/email/config-only.html`) |
| Kubernetes | `K8S_CONTEXTS` (JSON: context → `url`, `namespace`, `token`), `K8S_CONTEXT`, `K8S_INSECURE` (`false`), `K8S_CA_CERT` (PEM, base64 PEM or `file:///var/run/secrets/kubernetes.io/serviceaccount/ca.crt`; empty = system CAs) |
| Code review | `CODE_REVIEW_BASE_URL` (placeholder; set it per deployment), `CODE_REVIEW_USERNAME`/`_PASSWORD`/`_USERID`/`_USERTYPE`/`_COOKIE`, `CODE_REVIEW_INSECURE` (`true`: no certificate check, the reference default), `CODE_REVIEW_TOKEN_METHOD` (`POST`; `GET` matches the reference but puts the password in the URL, which the REST Invoke logs) |
| UI and MCP | `QASSIST_URL` (empty: QAssist not configured), `REST_PORT` (`9999`), `MCP_PORT` (`8081`) |

Secrets (`GITHUB_TOKEN`, database, SMTP, LLM and code review credentials) belong in the environment, not in the
`.flogo`.

## Notification e-mail

After each generation the app e-mails `NOTIFY_RECIPIENTS`. The e-mail is an HTML template with placeholders, so its
text, layout and branding change without touching a flow:

| Template | Sent after |
|----------|------------|
| [config/email/new-repository.html](../config/email/new-repository.html) (`NOTIFY_TEMPLATE`) | a generated repository |
| [config/email/config-only.html](../config/email/config-only.html) (`NOTIFY_TEMPLATE_CONFIG_ONLY`) | a config-only generation |

- The `<title>` is the subject.
- Placeholders: `{{repo_name}}`, `{{github_url}}` (the repository, or its folder, on GitHub), `{{clone_url}}`,
  `{{template_name}}`, `{{match_score}}`, `{{source_system}}`, `{{target_system}}`, `{{business_object}}`,
  `{{interface_type}}`, `{{env}}`, `{{cdm}}`, `{{generation_id}}` and `{{organization}}` (`NOTIFY_ORGANIZATION`,
  the footer). Values are HTML-escaped; an unknown placeholder stays as it is.
- `cid:email-logo.png` is the logo in `BRAND_LOGO_FILE`, attached inline.
- Comments (`<!-- … -->`) are removed before sending; conditional comments such as `<!--[if mso]>` are kept.
- The template is read for every e-mail, so an edit applies to the next one without a restart. If it cannot be read,
  the generation still succeeds, no e-mail is sent and the log shows
  `[NOTIFY] no e-mail for <repo>: cannot read the e-mail template: …`.

In a container, mount your templates over `/app/config/email`, for example on Kubernetes from a ConfigMap
(`kubectl -n bwce-ai-generator create configmap bwce-ai-generator-email --from-file=config/email/`) with this in
[deploy/kubernetes.yaml](../deploy/kubernetes.yaml):

```yaml
          volumeMounts:
            - { name: email-templates, mountPath: /app/config/email }
      volumes:
        - { name: email-templates, configMap: { name: bwce-ai-generator-email } }
```

The rendering itself is the jq programs `email.subject` and `email.message` in `config/ops-programs.json`.
