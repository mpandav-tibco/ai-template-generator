# Development

`bwce-ai-generator-github.flogo` is the source of truth; change it in the Flogo designer (VS Code) or with the Flogo
design CLI.

**Flow structure.** Every REST handler is an operation of the embedded API definition, one handler per flow, named
after the flow (see [Flows](flows.md)). Each handler maps the request (`pathParams`, `queryParams`, `body`) to the inputs
the flow declares, and the flow's `code` + `responseBody` outputs to the reply. Data-shaped logic (Kubernetes, e-mail,
code review, schema upload, CI/CD files) is jq programs in `config/ops-programs.json`, loaded into shared data at
startup (see [Operations](operations.md)). A jq input never holds a shared-data object itself: the mapper that builds
the input copies it (`coerce.toObject(coerce.toString(…))`), because `json.jq` rewrites its input in place and two
requests doing that to the same stored object at once crash the engine (`concurrent map iteration and map write`).

**Designer validation.** The designer's **Validate** reports no errors in any flow. It resolves every mapped path
against declared schemas and checks each expression's result type, so: the request-body flow inputs (`content`, the
MCP tools' `arguments`) carry the API definition's schema; the `APP_OPS` shared data declares every program key;
query activities list their output columns; `json.jq`/`array.get` results are wrapped in
`coerce.toArray`/`coerce.toString` where the target is typed; link conditions avoid a leading `!(`, which the
designer's expression parser rejects; error branches read `$error[<activity>]`. Each flow's `metadata.fe_metadata`
matches its inputs and outputs (a stale copy makes the designer rewrite flow inputs on save).

**Saving in the designer.** A save in the Flogo designer (2.26.8) rewrites the connection properties. Check the diff
of `properties` and `connections` afterwards and keep: `weaviate.WeaviateTemplateKB.Timeout_Seconds` and
`Retry_Backoff_Ms` (the designer renames them to names with parentheses, which Kubernetes environment variables
cannot set), `weaviate.WeaviateTemplateKB.Scheme` and the connection's `scheme` bound to it (the designer replaces
the binding with `http`, so an https Weaviate could no longer be configured), and the `=$property[...]` form of the
PostgreSQL `tlsconfig` and `tlsparam` settings.

**Changing the API.** Add or change the operation in the app's API definition first (Flogo designer, API specs; the
designer offers Method and Path from it), then add the flow and its handler. Flogo's `/api/v2/swagger.json` serves
the result.

## Repository layout

```text
bwce-ai-generator-github.flogo   the Flogo application
config/ci-bwcetemplates.json     template catalog (ingested into Weaviate)
config/ikd/                      IKD interface and scenario id lists
config/email/                    notification e-mail templates (HTML with {{placeholders}})
config/ops-programs.json         jq programs: Kubernetes, code review, schema upload, CI/CD file templates, e-mail
deploy/                          container image, Kubernetes manifest, settings and secrets templates
rules/                           rule engine packs: nlu-extraction.yaml, spec-validation.yaml
static/                          web UI (chat-github.html), e-mail logo
```

## Differences from the reference generator

Sign-in, accounts, roles and the audit log (Entra ID SSO included) are left to Kong; the code review network check
infers DNS/TCP/TLS from one HTTP probe; rollout status is a snapshot (no blocking wait); schema upload takes JSON
instead of multipart, requires a previously generated repository (404 otherwise) and also accepts OpenAPI/Swagger
files (to `Service Descriptors`, like WSDLs); `CODE_REVIEW_INSECURE` replaces
the reference's `CODE_REVIEW_VERIFY_SSL`, because the REST Invoke binds "Disable SSL Verification" to a property, not
an expression.
