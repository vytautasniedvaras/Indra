---
title: Knowledge Graph Tooling
type: decision
tags:
- process
- docs
permalink: indra/decisions/knowledge-graph-tooling
---

This knowledge graph uses Basic Memory (ADR 0014): Markdown files ARE the store, so
humans browse it on GitHub with zero tooling, while AI sessions query it via MCP
(`.mcp.json`) or `scripts/bm`. Chosen over the MIT reference memory server (JSONL blob —
unreadable for humans) and DB-backed options (Graphiti/Cognee/Kuzu — services or binary
artifacts in git).

- [constraint] The files are the source of truth; the tool is an accelerator. If basic-memory breaks, the graph is still plain docs
- [gotcha] Environment quirks (proxy interception of localhost, blocked embedding-model download) are handled inside `scripts/bm` — always go through the wrapper

## Relations

- documented_in [[Knowledge Graph README]]