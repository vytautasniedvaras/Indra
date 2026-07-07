---
title: README
type: note
permalink: indra/readme
---

# Indra knowledge graph

This folder is a knowledge graph of the project: what the pieces are, why they are the
way they are, and what must never be broken — as plain Markdown, readable on GitHub,
and machine-queryable with [Basic Memory](https://github.com/basicmachines-co/basic-memory)
(tool choice: ADR 0014).

It complements, never replaces, the authoritative docs: `docs/BUILD_SPEC.md` (spec),
`docs/architecture.md` (maintenance guide), `docs/adr/` (decisions), `docs/api.md`
(wire contract). Notes here stay SHORT and link out; their value is the **graph** —
following relations from a module to the invariants that constrain it to the decision
that shaped it.

## Reading it (humans)

Just browse. Every note is Markdown with three ingredients:

```markdown
---
title: Job System
type: module
tags: [backend]
---
Facts as bullet "observations", categorized:
- [design] Spawn-context ProcessPoolExecutor; Manager Event/Queue bridge to asyncio #jobs
Relations as wiki-links (this is the graph):
- constrained_by [[Cancellation Checks]]
- decided_by [[ADR 0003]]
```

Folders group entity types: `modules/`, `invariants/`, `decisions/`, `process/`.

## Querying it (AI devs and CLI humans)

Use `scripts/bm` (self-bootstrapping wrapper — installs the tool, registers this folder
as the `indra` project, applies the two environment fixes documented inside it):

```bash
scripts/bm tool search-notes "cache key"        # full-text search
scripts/bm tool read-note "modules/job-system"  # one note
scripts/bm tool recent-activity                 # what changed lately
scripts/bm orphans                              # notes with no relations (fix them)
```

Claude Code sessions get the same operations as MCP tools automatically via the
committed `.mcp.json` (server: `basic-memory`).

## Writing to it (both)

Add or edit Markdown directly (preferred for humans — it's just files, commit as usual),
or via `scripts/bm tool write-note` / the MCP `write_note` tool. Conventions:

- One entity per note; filename = title. Keep under ~30 lines; link, don't duplicate.
- `type:` one of `module | invariant | decision | process | concept`.
- Observations: `- [category] fact #tag` — categories in use: `design`, `constraint`,
  `gotcha`, `perf`, `status`.
- Relations: `- relation_verb [[Other Note Title]]` — verbs in use: `constrained_by`,
  `decided_by`, `depends_on`, `implements`, `documented_in`, `supersedes`.
- A wiki-link to a note that doesn't exist yet is fine (forward reference) — but run
  `scripts/bm orphans` occasionally and connect strays.
- After editing files by hand, run `scripts/bm sync` (file edits reach the search index
  only while a server is running; in Claude Code sessions the MCP server does this
  automatically). The tool also normalizes frontmatter (adds `permalink:`) on sync —
  commit that churn, it's expected.

**When to update**: same rule as STATUS.md — whenever you land work that adds a module,
changes an invariant, or makes a decision a future developer would need to rediscover
the hard way.