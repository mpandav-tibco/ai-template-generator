#!/bin/bash
# BWCE AI Generator - API Test Suite
# Run after starting the Flogo application on port 8080

BASE_URL="http://localhost:8080"

echo "=== BWCE AI Generator Test Suite ==="
echo ""

# 1. Health Check
echo "--- [1] Health Check ---"
curl -s -X GET "$BASE_URL/health" | head -200
echo ""

# 2. List Templates
echo "--- [2] List Templates ---"
curl -s -X GET "$BASE_URL/api/templates" | head -200
echo ""

# 3. Chat Init - new session
echo "--- [3] Chat Init (new session) ---"
SESSION_RESPONSE=$(curl -s -X POST "$BASE_URL/api/chat/init" \
  -H "Content-Type: application/json" \
  -d '{}')
echo "$SESSION_RESPONSE"
SESSION_ID=$(echo "$SESSION_RESPONSE" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
echo "Session ID: $SESSION_ID"
echo ""

# 4. Chat Message - send integration description
echo "--- [4] Chat Message - Describe integration ---"
curl -s -X POST "$BASE_URL/api/chat/message" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"message\": \"I need to publish S4HANA article data to Kafka\"}"
echo ""

# 5. Chat Message - answer follow-up
echo "--- [5] Chat Message - Follow-up answer ---"
curl -s -X POST "$BASE_URL/api/chat/message" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\", \"message\": \"This is a pub interface, no CDM needed\"}"
echo ""

# 6. Extract - one-shot extraction
echo "--- [6] Extract (one-shot NLU) ---"
curl -s -X POST "$BASE_URL/extract" \
  -H "Content-Type: application/json" \
  -d '{
    "message": "from wms to kafka for salesorder sub interface",
    "current_spec": {}
  }'
echo ""

# 7. Generate - complete spec generation
echo "--- [7] Generate Repository ---"
curl -s -X POST "$BASE_URL/generate" \
  -H "Content-Type: application/json" \
  -d '{
    "spec": {
      "source_system": "s4hana",
      "target_system": "kafka",
      "business_object": "article",
      "interface_type": "pub",
      "template_type": "S4HANA_PUB_To_KAFKATopic_CDM",
      "cdm": true,
      "email": "developer@adidas.com",
      "env": "DEV",
      "k8s_domain": "cite",
      "scenario_id": "1234",
      "bw_profile": "default"
    }
  }'
echo ""

# 8. Chat Reset
echo "--- [8] Chat Reset ---"
curl -s -X POST "$BASE_URL/api/chat/reset" \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"$SESSION_ID\"}"
echo ""

echo "=== Test Suite Complete ==="
