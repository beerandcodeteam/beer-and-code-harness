---
description: Interview the developer, discover the stack, and produce a structured project description at .spec/init/project-description.md
argument-hint: "[one-line idea of the project]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion, WebSearch
---

# init:project-description

You are helping a developer turn a rough idea into a **clear, structured project description**. 
This document is the first artifact of the project spec. It is written *before* code and becomes the shared source 
of truth for what is being built and why.

The developer's initial idea (may be empty):

```
$ARGUMENTS
```

## Your goal

Produce a single document at **`.spec/init/project-description.md`** that:

1. Sharpens the idea — turns a vague concept into concrete scope.
2. Surfaces **definition gaps** — the ambiguities and unmade decisions that would block development — and resolves them *with the developer*.
3. Structures the **tech stack** — normally discovered from the project environment, not guessed.
4. Extracts the **core concepts** (the domain vocabulary).
5. Defines the **core workflows** (the main flows the system performs).

## Process

### 1. Discover the environment first

Before asking anything, inspect the project so you don't ask what you can detect. Look for stack signals:

- Manifests / lockfiles: `composer.json`, `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`, `*.csproj`, etc.
- Framework markers: `artisan`, `manage.py`, `next.config.*`, `nuxt.config.*`, `vite.config.*`, `docker-compose.yml`, `Dockerfile`.
- Config/env: `.env.example`, CI files, test runner config.
- Existing docs: `README*`, any files already under `.spec/`.

Read enough to name the stack with real versions. If the directory is empty or pre-code, note that and derive the stack from the developer's stated intent instead (still confirm it).

### If the target file already exists (re-run)

Re-running this command must **update** the existing document, never rebuild it from scratch — `.spec` belongs to the developer, and manual edits there are decisions, not noise.

- Read the existing `.spec/init/project-description.md` **before** interviewing. Every decision recorded in it is source of truth.
- Interview only about **deltas**: new gaps, new scope, contradictions between the doc and what you detected in the environment. Never re-ask what the document already answers.
- Update via **Edit**, not a full rewrite. Preserve the numbering of `## Core Workflows` (`### 1.`, `### 2.` …): new workflows take the next number at the end; never renumber existing ones — downstream artifacts reference them by number in their coverage tables.
- A section, workflow, or concept the developer deleted stays deleted — restore it only if the developer explicitly confirms.

### 2. Interview to close gaps

Understand the idea, then find what's undefined. Ask the developer about the gaps that actually matter — do not interrogate on things you can infer or that don't change the shape of the system. Focus on:

- **Purpose & audience** — who uses it, what problem it solves.
- **Scope / MVP boundary** — what is in the first version vs deferred.
- **Core domain concepts** — the nouns and rules that define the game/product/API.
- **Core workflows** — the main flows, step by step.
- **Constraints** — auth model, integrations, platform, non-goals.

Use `AskUserQuestion` for discrete decisions with clear options. Ask real open questions in plain text when the answer is not a menu. Batch related questions; don't drip one at a time. Keep going until you can write each section without hand-waving. When something stays undecided, mark it explicitly as an open question rather than inventing an answer.

### 3. Write the document

Write to `.spec/init/project-description.md` (create the `.spec/init/` directories if missing). Match the developer's language. Use **exactly** this structure:

```markdown
# <Project Name> — Project Description

## Overview

<2–4 paragraphs: what it is, who it's for, the core loop/value, the MVP boundary. Bold the key ideas.>

### Key Concepts

- **<Concept>:** <definition, including rules/limits/numbers where they exist>
- ...

## Tech Stack

<A table (Layer | Technology) or grouped bullets, whichever fits. Use real detected versions. One row/line per meaningful layer: backend, frontend, database, testing, dev env, tooling, integrations.>

## Core Workflows

### 1. <Workflow Name>

<Numbered steps or prose describing the flow. Include request/response examples in fenced code blocks where the workflow is an API. Be concrete about rules, limits, and edge cases.>

### 2. <Workflow Name>
...
```

Rules for the document:

- **Title** = project name + `— Project Description`.
- **Overview** carries the "what & why"; **Key Concepts** is the domain glossary; **Tech Stack** is concrete and detected; **Core Workflows** is the numbered list of main flows.
- Prefer specific numbers, limits, and rules over vague description. If the domain has quantities (counts, tiers, scoring), state them.
- Keep every claim traceable to something the developer confirmed or you detected. No invented features.
- If gaps remain unresolved, add a short `## Open Questions` section at the end listing them. Otherwise omit it.

### 4. Self-checks (run until green)

After writing, run these checks. Any failure → fix the document via Edit and re-run until all pass. Never report completion with a failing check.

```bash
F=.spec/init/project-description.md
test -f "$F"
head -1 "$F" | grep -qE '^# .+ — Project Description$'
grep -Fq '## Overview' "$F"
grep -Fq '### Key Concepts' "$F"
grep -Fq '## Tech Stack' "$F"
grep -Fq '## Core Workflows' "$F"
[ "$(grep -cE '^### [0-9]+\. ' "$F")" -ge 1 ]      # >=1 numbered workflow
[ "$(grep -cE '^- \*\*[^*]+:\*\*' "$F")" -ge 1 ]   # >=1 key concept entry
```

### 5. Close out

After writing, report:

- The path written.
- A 3–5 line summary of the project as captured.
- Self-checks: all green — list any check that initially failed and how it was fixed (Red → Green).
- Any open questions still needing the developer's decision.
