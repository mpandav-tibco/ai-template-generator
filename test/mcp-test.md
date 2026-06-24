# MCP Server Test Guide

## Connect from Claude Desktop / Cursor / VS Code

Add to your MCP client config — the server speaks **Streamable HTTP** at `/mcp`:
```json
{
  "mcpServers": {
    "bwce-ai-generator": {
      "url": "http://localhost:8081/mcp"
    }
  }
}
```
> VS Code `.vscode/mcp.json`: `{ "servers": { "bwce-ai-generator": { "type": "http", "url": "http://localhost:8081/mcp" } } }`

## Available MCP Tools

### 1. extract_spec
Extracts a structured BWCE spec from natural language. Supports multi-turn refinement via `current_spec`.

**Arguments:**
```json
{ "message": "publish sales order from s4hana to kafka, scenario 1234, PROD, CDM required", "current_spec": {} }
```

**Returns** — the extracted spec plus what is still missing:
```json
{
  "success": true,
  "ready_to_generate": false,
  "spec": {
    "source_system": "S4HANA", "target_system": "KAFKA",
    "business_object": "sales order", "interface_type": "pub", "cdm": "true",
    "template_type": "", "scenario_id": "1234"
  },
  "missing": { "business_object": false, "template_type": true },
  "message": "Some required fields are still missing. Please provide the missing values."
}
```

### 2. generate_code
Validates a spec, registers it idempotently in PostgreSQL, and returns a confirmation. The `spec` is a **nested** object.

**Arguments:**
```json
{
  "spec": {
    "source_system": "s4hana", "target_system": "kafka",
    "business_object": "article", "interface_type": "pub",
    "template_type": "S4HANA_PUB_To_KAFKATopic", "email": "dev@adidas.com"
  }
}
```

**Returns** — a text result. New spec:
```
Generation registered. Repository: s4hana-article-kafka-pub | template_type: S4HANA_PUB_To_KAFKATopic
```
Re-running the same spec (idempotent):
```
Repository already exists: s4hana-article-kafka-pub (duplicate - not regenerated).
```

### 3. list_templates
Lists all 25 available BWCE integration templates with their metadata.

**Arguments:** `{}`  ·  **Returns:** `{ "templates": [ … 25 … ] }`

## Quick test from the shell
The demo helper performs the full MCP handshake (`initialize` → `initialized` → `tools/call`):
```bash
./demo/mcp-demo.sh list_templates
./demo/mcp-demo.sh extract_spec  '{"message":"publish sales order from s4hana to kafka"}'
./demo/mcp-demo.sh generate_code '{"spec":{"source_system":"s4hana","target_system":"kafka","business_object":"article","interface_type":"pub","template_type":"S4HANA_PUB_To_KAFKATopic","email":"dev@adidas.com"}}'
```

## Test with MCP Inspector
```bash
npx @modelcontextprotocol/inspector
# then connect to:  http://localhost:8081/mcp   (transport: Streamable HTTP)
```
