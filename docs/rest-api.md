# REST API

The API definition (OpenAPI 3) is embedded in the app, and Flogo serves it: start the app with
`FLOGO_EXPOSE_SWAGGER_EP=true` and fetch `GET /api/v2/swagger.json` on the REST port (for Swagger UI, Postman or any
OpenAPI tool).

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Web UI |
| GET | `/health` | Liveness and readiness probe |
| POST | `/api/chat/init`, `/api/chat/message`, `/api/chat/reset` | Conversation that builds the spec (sessions in PostgreSQL) |
| POST | `/extract` | One-shot spec extraction from free text |
| GET | `/api/templates` | Template catalog |
| POST | `/api/templates/suggest` | Ranked templates for a (partial) spec; `/generate` uses the same search |
| POST | `/generate` | Generate and publish (`spec`, `config_only`, `target_mode`) |
| GET | `/api/tracker` | Generated repositories (`count` and `records`) with their GitHub location, the template source and UI settings |
| DELETE | `/api/tracker/{repo_name}` | Clean up a generated repository |
| GET | `/api/ikd?kind=InterfaceIDs\|ScenarioIDs` | IKD registry in the reference `IKD_*.txt` format (`<id>:<repo>` lines) |
| POST | `/api/schemas/upload/{kind}` | Commit schema files into a generated repository's module: XSD to `code/<repo>/<repo>.module/Schemas`, WSDL and OpenAPI/Swagger to `code/<repo>/<repo>.module/Service Descriptors` (`source`, `target`, `batch`) |
| POST | `/api/codereview/token`, `/api/codereview/run` | Code review token, code review run |
| GET | `/api/codereview/history`, `/api/codereview/network-debug` | Code review history, connectivity check |
| GET | `/k8s/{resource}`, `/k8s/{resource}/{name}`, `/k8s/{resource}/{name}/{view}` | Cluster health, context, status, lists, one item, rollout, logs, port-forward |
| POST | `/k8s/deployments/{name}/{action}`, `/k8s/context/switch` | Scale or restart a deployment, switch the context |

Every operation except `/` and `/health` is also an [MCP tool](mcp.md).
