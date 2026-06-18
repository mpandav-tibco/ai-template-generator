---
marp: true
theme: default
paginate: true
title: BWCE AI Generator — Demo
---

<!-- ============================================================ -->
<!-- SLIDE 1 — Title / The Problem -->
<!-- ============================================================ -->

# BWCE AI Generator
### Plain English → production-ready TIBCO BWCE integration repos

**The problem**
- Creating a new BWCE integration repo is manual, repetitive, and error-prone
- Developers must know the right template, naming rules, IKD ids, and CDM conventions
- No guardrails → duplicates, wrong metadata, inconsistent scaffolding

**The idea**
> Describe the integration in a sentence. Let an agent extract the spec, validate it, pick the template, and scaffold the repo — with full governance.

*Built entirely on TIBCO Flogo Agentic AI — REST API + MCP server.*

---

<!-- ============================================================ -->
<!-- SLIDE 2 — What it does / Architecture -->
<!-- ============================================================ -->

# How it works

**One natural-language request drives the whole pipeline:**

`"publish IKD-007 article from s4hana to kafka, scenario 1234, PROD, CDM required"`

| Stage | Capability |
|-------|------------|
| **Understand** | Deterministic rule-engine pre-extract **+** LLM (local Ollama) |
| **Select** | Best-matching template via **Weaviate** vector search (RAG) |
| **Govern** | **IKD cross-check** + **idempotent** registry (PostgreSQL) |
| **Deliver** | Scaffolds the repo + sends a **notification email** |

**Two front doors:** REST API (`:9999`) for UIs · MCP server (`:8081`) for Claude / Copilot agents

---

<!-- ============================================================ -->
<!-- SLIDE 3 — Live Demo flow -->
<!-- ============================================================ -->

# Live demo — what you'll see

1. **Health + template catalog** — app up; templates ingested into Weaviate on startup
2. **/extract** — one-shot NLU turns a sentence into a structured spec
3. **/api/chat** — multi-turn conversation fills in missing fields
4. **/generate** — the full pipeline runs end-to-end → repo created
5. **Re-run /generate** — duplicate detected, returns existing record *(idempotent)*
6. **Bad IKD id** — request rejected before any side effects *(guardrail)*

**Proof of side effects, live:**
- PostgreSQL `generation_log` row · scaffolded `generated-repos/…/manifest.json` · email in MailDev inbox

*Driven by two scripts: `./demo/start-demo.sh` then `./demo/run-demo.sh`*

---

<!-- ============================================================ -->
<!-- SLIDE 4 — Why it matters / Engineering highlights -->
<!-- ============================================================ -->

# Why it matters

**Business value**
- Minutes → seconds to stand up a compliant integration repo
- Governance built in: IKD validation, no duplicates, consistent naming & metadata
- Self-service for developers via chat **or** agents (MCP)

**Engineering highlights**
- **Deterministic + LLM hybrid** — rules pull high-confidence signals, so small local models are reliable
- **Fence-tolerant JSON parsing** — handles real-world LLM output (prose + code fences)
- **100% Flogo-native** — no custom microservice; REST + MCP from one app
- Validated **end-to-end against live PostgreSQL, Weaviate, Ollama & SMTP**

---

<!-- ============================================================ -->
<!-- SLIDE 5 — Summary / Next steps -->
<!-- ============================================================ -->

# Summary & next steps

**Delivered**
- Conversational + one-shot spec extraction
- Template RAG, IKD governance, idempotent generation
- Repo scaffolding + notifications — all on TIBCO Flogo Agentic AI

**Next steps**
- Wire scaffolding to real Bitbucket/Git repo creation
- Expand the template library & IKD coverage
- Add CI hooks and richer approval workflows
- Promote from local Ollama to the platform LLM endpoint

**Try it:** `./demo/start-demo.sh --build` → `./demo/run-demo.sh`

### Questions?
