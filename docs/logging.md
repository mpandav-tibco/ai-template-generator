# Logging

Every flow that changes something or answers a business question logs its outcome in one line that names the flow:

```text
INFO [flogo.general.activity.log] - [GENERATE] done: repo=incsdsourcing-s4hana-shipment-kafka-d55638-pub, template=SFTPGet_To_KAFKATopic (vector, score 1), target_mode=subfolder, write_mode=api, config_only=false, files=88, pushed=true, commit=6b03a0a…, url=https://github.com/…, scaffold_ms=6145. FlowInstanceID [efe8e68a…-1], Flow [generate_POST], Activity [LogGenerated].
```

| Tag | Flows | Logged |
|-----|-------|--------|
| `[STARTUP]` | StartupFlow | the configuration in use (target, templates, LLM and embeddings, Weaviate, registry, SMTP, Kubernetes context, code review URL, ports; no secrets), then the number of ingested templates |
| `[GENERATE]` | generate_POST | the normalized request, then the outcome: published (template, score, modes, files, commit, URL, time), duplicate, or rejected by the validation rules or the IKD check |
| `[NOTIFY]` | SendNotificationFlow | subject and recipients of the e-mail, or why none was sent |
| `[EXTRACT]`, `[CHAT]`, `[SUGGEST]` | ExtractSpecCore, extract_POST, api_chat/message_POST, api_templates_suggest_POST | what the LLM extracted, the fields still missing after each chat message, how many templates were suggested for which search |
| `[SCHEMAS]` | schemas_upload_POST | the committed files (commit, URL) or why the upload was rejected |
| `[CLEANUP]` | api_tracker_repo_DELETE | the removed folder and registry rows, or why nothing was removed |
| `[K8S]` | K8sOperation | operation, parameters (context, namespace, name, replicas) and HTTP status; context switches |
| `[CODEREVIEW]` | codereview_run_POST, CodeReviewToken | run outcome and sign-in (the token itself is never logged) |
| `[ERROR]` | error handlers of the REST flows | the failed activity, code and message |

- Each line ends with `FlowInstanceID`, `Flow` and `Activity`. A subflow's instance id is its caller's id with another
  suffix (`…-1` for the REST flow, `…-4` for the e-mail it sends), so the lines of one request share the id before
  the dash. The triggers add `Executing handler [<flow>]` (REST) and `Executing Tool [<tool>]` (MCP) per request.
- Successes are INFO, rejections and failed Kubernetes operations WARN, flow failures ERROR. Messages carry names,
  counts, outcomes and URLs, never secrets or file contents, and line breaks in values are replaced, so a request
  cannot forge log lines. The MCP trigger itself logs each tool call with its arguments at INFO, which includes the
  file contents passed to `upload_schemas`.
- `FLOGO_LOG_LEVEL` sets the level (`INFO` by default; `WARN` keeps only rejections and failures) and
  `FLOGO_LOG_FORMAT=JSON` writes one JSON object per line for a log platform.
