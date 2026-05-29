# MCP Server Test Guide

## Connect from Claude Desktop / Cursor / VS Code

Add to your MCP config:
```json
{
  "mcpServers": {
    "bwce-ai-generator": {
      "url": "http://localhost:8081",
      "transport": "sse"
    }
  }
}
```

## Available MCP Tools

### 1. extract_spec
Extracts BWCE integration specification from natural language.

**Input:**
```
"I need to publish S4HANA article data to Kafka with CDM transformation"
```

**Returns:**
```json
{
  "source_system": "s4hana",
  "target_system": "kafka",
  "business_object": "article",
  "interface_type": "pub",
  "cdm": true
}
```

### 2. generate_repository
Generates a BWCE repository from a complete spec.

**Input:**
```json
{
  "source_system": "s4hana",
  "target_system": "kafka",
  "business_object": "article",
  "interface_type": "pub",
  "template_type": "S4HANA_PUB_To_KAFKATopic_CDM",
  "cdm": true,
  "email": "dev@adidas.com"
}
```

**Returns:**
```json
{
  "repo_name": "s4hana-article-kafka-pub",
  "shell_command": "./GenerateCodeFromTemplate.sh -n s4hana-article-kafka-pub ...",
  "valid": true
}
```

### 3. list_templates (Resource)
Lists all 25 available BWCE integration templates with their metadata.

## Test with MCP Inspector
```bash
npx @modelcontextprotocol/inspector http://localhost:8081
```
