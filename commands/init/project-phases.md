---
description: Read the project description, user stories, database schema, and any design specs, then plan the build into numbered, agent-ready phases with tasks, acceptance criteria, and feature tests at .spec/init/project-phases.md
argument-hint: "[optional focus area or extra context]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# init:project-phases

**ultrathink.** This is a high-stakes planning task: the document you produce is fed to AI agents that build the whole project from it. Engage your maximum reasoning budget. Do not rush. Precision, completeness, and faithful coverage of every source document matter more than brevity.

You are helping a developer turn the project spec into a **complete, phased implementation plan**. This document is the fourth artifact of the project spec. It builds on the first three (and any design specs) and becomes the ordered backlog AI agents implement, phase by phase, referenced by number.

Optional focus or extra context from the developer (may be empty):

```
$ARGUMENTS
```

## Your goal

Read the existing spec and produce a single document at **`.spec/init/project-phases.md`** that:

1. Breaks the entire build into **numbered phases and sub-phases** (`Phase 1`, `Phase 5.3`, …) that can be referenced by number when later handed to an AI agent.
2. Lists **every task** required to implement everything in the project description, user stories, and database schema — nothing implied by the spec is left unplanned.
3. Gives each task concrete **acceptance criteria** and, where the task carries business logic, the **automated feature tests** to be generated as its acceptance gate.
4. Marks tasks **already completed in the codebase** as `[x]`.
5. Orders the work **foundation-first**, then feature flows.

## Process

### 1. Read the sources of truth first

Before asking anything, read the inputs in this order:

- **`.spec/init/project-description.md`** — scope, tech stack, core workflows.
- **`.spec/init/user-stories.md`** — the stories, acceptance criteria, priorities.
- **`.spec/init/database-schema.md`** — every table, lookup, pivot, relationship.
- **`.spec/init/design/`** — if this directory exists, it holds the **UI/design specs** (mockups, screen definitions, component references, images). Read it. Every task that builds a screen or component **must** point at its design reference, and its implementation must be **faithful to the proposed design**. `.spec/init/design/` is always a **manual artifact**: the developer creates and populates it; no `init:*` command writes there. Its absence is never an error.

If any of the first three files is missing, stop and tell the developer to run the missing `init:*` command first. Match the **language** of the project description for all prose.

Then verify the chain is internally fresh — line 3 of each generated artifact records the inputs it was built from:

```bash
# prints nothing when fresh; any output = an input changed after that artifact was generated
for doc in user-stories database-schema; do
  for pair in $(sed -n '3p' ".spec/init/$doc.md" | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
    [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
      || echo "stale: $doc.md predates current ${pair%%@*}"
  done
done
```

Any output → warn the developer ("input changed after this artifact was generated — review before proceeding") and suggest re-running the flagged `init:*` command first. Warn and proceed if the developer chooses; never block. A file without a line-3 stamp predates this mechanism — nothing to verify.

### If the target file already exists (re-run)

Re-running this command must **update** the existing document, never rebuild it from scratch — `.spec` belongs to the developer, and manual edits there are decisions, not noise.

- Read the existing `.spec/init/project-phases.md` **before** interviewing. Every decision recorded in it (ordering, MVP cut, task status) is source of truth.
- Interview only about **deltas**: stories or tables added upstream since the last run, new gaps, contradictions. Never re-ask what the document already answers.
- Update via **Edit**, not a full rewrite. Preserve every existing `Phase N` / `Phase N.M` number: new phases and sub-phases take the next number at the end (see Numbering); never renumber — agents are handed phases by number.
- Never flip a task the developer marked `[x]` back to `[ ]` without explicit confirmation. Codebase re-inspection (step 2) may add new `[x]` marks as usual.
- A phase, task, or section the developer deleted stays deleted — restore it only if the developer explicitly confirms.

Line 3 of the existing file is its **input stamp** (see step 4). Verify it before interviewing:

```bash
# prints nothing when fresh; any output = that input changed after this document was generated
for pair in $(sed -n '3p' .spec/init/project-phases.md | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
  [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
    || echo "stale: ${pair%%@*} changed after this document was generated"
done
```

Any output → warn the developer ("input changed after this artifact was generated — review before proceeding") and focus the delta interview on what changed in that input. Warn and proceed; never block. A file without a line-3 stamp predates this mechanism — nothing to verify.

### 2. Inspect the codebase to detect what is already done

Extract the framework/ORM from the project description's Tech Stack section — they determine where persistence, models, and tests actually live. Confirm against the codebase manifest (`composer.json`, `package.json`, `pyproject.toml`, `go.mod`, `Gemfile`, …) or a quick `Glob` when one exists; do not assume Laravel's layout.

Scan the project so you can mark completed work:

- Migrations/schema and models in the detected stack's own layout (e.g. `database/migrations/` + `app/Models/` for Laravel, `alembic/versions/` + `app/models/` for FastAPI+SQLAlchemy, `prisma/migrations/` + `schema.prisma` for Prisma), seeders/factories.
- Frontend components, pages/screens, routes.
- Existing tests (wherever the stack's test runner looks for them), controllers/handlers/routers, services, request validation, authorization/policy layers.

For each task you define, check whether the code already satisfies it. If it does, mark it `[x]`; otherwise `[ ]`. When partially done, mark `[ ]` and note in the task what remains.

### 3. Interview to close gaps

Derive as much of the plan as you can directly from the docs, then ask the developer only about gaps that change the **shape, ordering, or sizing** of phases — do not interrogate on things the docs already answer. Focus on:

- **Phase priorities / ordering** — which feature flows come first after the foundation.
- **MVP cut line** — which phases are in the first release vs deferred.
- **Ambiguous scope** — flows implied but not fully specified in the stories.
- **Design coverage** — screens with no design reference: build to a sensible default, or wait for design?

Use `AskUserQuestion` for discrete decisions with clear options. Ask real open questions in plain text when the answer is not a menu. Batch related questions; don't drip one at a time. When something stays undecided, mark it as an open question rather than inventing scope.

## Rules for phasing

### Foundation first, always

Order the phases so that **foundation work precedes feature flows**. The early phases build the base the rest stands on:

1. **Database foundation** — all migrations and lookup-table seeders from the schema.
2. **Models & relationships** — every model, with **all relationships wired up front** (belongsTo, hasMany, belongsToMany, etc.), casts, fillables, soft deletes. Do not defer relationships to later feature phases — the models come out of the foundation phase relationship-complete.
3. **Frontend foundation** — the base UI: design-system components, layout, shared/reusable components referenced by the design specs.

Only **after** the foundation is in place do the phases start implementing the **project flows** (auth, then each feature area / core workflow, feature by feature).

### Phase sizing (one agent session per phase)

Size each phase so a single AI agent can implement it in **one focused session, within one context window** — big enough to be a coherent, shippable slice, small enough to fit comfortably without overflow.

Working heuristic: a phase (parent + all its sub-phases) covers **one feature area or one foundation layer** and stays around **10–15 tasks**. Beyond that, split into more top-level phases.

- **Sub-phases count toward their parent phase's session.** A parent phase plus all its sub-phases together must still fit one session. If the total grows too large, split it into more top-level phases instead of overloading one parent.
- Prefer more, well-scoped phases over a few oversized ones. **Any number of phases is fine** as long as each is detailed enough to implement everything in the description, stories, and schema with high quality and precision.
- Keep each phase independently implementable and, where possible, independently verifiable.

### Numbering

- Top-level phases: `Phase 1`, `Phase 2`, … Sub-phases: `Phase 5.1`, `Phase 5.2`, `Phase 5.3`, … so any unit can be referenced by number when handed to an agent.
- Keep numbers **stable**; don't renumber existing phases when adding new ones.

The heading format is not a style choice — it is a **machine contract** with `scripts/ralph.sh`, which executes this document phase by phase:

- `split_phases` matches top-level headings against the regex `^##[[:space:]]+Phase[[:space:]]+[0-9]+` and cuts the document into **one file — one agent session — per `## Phase N:` heading**. A phase heading that deviates (wrong level, missing number, `Phase` misspelled or translated) silently disappears from the run.
- Sub-phases **must** stay at level 3 (`### Phase N.M:`). Promoting one to `##` makes ralph split it into its own session, breaking the sizing rule that a parent and its sub-phases share one session.
- Any other level-2 heading (`## Overview`, `## Open Questions`) **ends capture**: content under it belongs to no phase and is never handed to an agent. Everything an agent needs to implement a phase must live under that phase's `## Phase N:` heading.

The self-checks in step 5 enforce this format mechanically.

### Tasks, tests, and acceptance criteria

- Every task has **acceptance criteria** — concrete, validatable conditions (states, limits, failure paths), not vague intent.
- **Business-logic tasks** (rules, calculations, state transitions, permissions, validations, workflows) **must** specify the **automated feature tests** to generate. Tests **primarily assert business rules** — the limits, states, and edge cases from the stories and schema.
- **Frontend-only tasks** (building a screen/component with no business logic) **do not require tests**, but **must** have acceptance criteria that can be validated (matches design reference, renders required elements/states, responsive/interaction behavior), plus a **Design ref** pointing at the relevant `.spec/init/design/` artifact.
- Keep every task traceable to a story (`US-x.y`), a schema table, a workflow, or a design artifact. No invented scope.

### 4. Write the document

Write to `.spec/init/project-phases.md` (create the `.spec/init/` directories if missing). Use **exactly** this structure:

````markdown
# <Project Name> — Project Phases

<!-- inputs: project-description.md@sha256:<first 12 chars> user-stories.md@sha256:<first 12 chars> database-schema.md@sha256:<first 12 chars> -->

## Overview

<1–2 paragraphs: the build strategy at a glance — foundation-first, then feature flows. Note how many phases, the MVP cut line, and that phases are referenced by number when handed to agents.>

**Conventions:**
- `[ ]` pending · `[x]` done in the codebase.
- Phases and sub-phases are numbered (`Phase 1`, `Phase 5.3`) for reference by AI agents.
- Business-logic tasks list the **feature tests** to generate; frontend-only tasks list validatable **acceptance criteria** and a **Design ref**.

---

## Phase 1: <Foundation — Name>

**Goal:** <one line.> · **Depends on:** <none / Phase N> · **Covers:** <stories/tables/workflows>

### Phase 1.1: <Sub-phase name>

- [ ] **Task:** <what to build>
  - **Acceptance criteria:**
    - <concrete, validatable condition>
    - ...
  - **Feature tests:** <test name → what business rule it asserts> *(omit for frontend-only tasks)*
  - **Design ref:** <path under .spec/init/design/> *(only for screen/component tasks)*
  - **Traces:** <US-x.y / table / workflow>

- [x] **Task:** <already implemented in the codebase>
  - ...

### Phase 1.2: <Sub-phase name>
...

---

## Phase 2: <Name>
...

## Open Questions

<Only if gaps remain — bullets of undecided scope/ordering. Otherwise omit this section.>
````

Rules for the document:

- **Title** = project name + `— Project Phases`.
- **Line 3** is the machine-owned **input stamp**: `<!-- inputs: project-description.md@sha256:<12 chars> user-stories.md@sha256:<12 chars> database-schema.md@sha256:<12 chars> -->`, each checksum being `sha256sum <file> | cut -c1-12` over the files as read in step 1. Refresh it on **every** run, including re-run Edits — the chain status uses it to detect drift. Never preserve a stale stamp as a "developer edit".
- Foundation phases come first; models are relationship-complete out of the foundation.
- Every phase (parent + its sub-phases) fits one agent session (see Phase sizing).
- Every task is traceable; every business-logic task has feature tests; every screen task has a design ref (or an open question if design is missing).
- Cover **everything** in the description, stories, and schema. Completeness beats brevity.

### 5. Self-checks (run until green)

After writing, run these checks. Any failure → fix the document via Edit and re-run until all pass. Never report completion with a failing check.

```bash
F=.spec/init/project-phases.md
test -f "$F"
head -1 "$F" | grep -qE '^# .+ — Project Phases$'
# line 3 input stamp present and fresh
[ "$(sed -n '3p' "$F")" = "<!-- inputs: project-description.md@sha256:$(sha256sum .spec/init/project-description.md | cut -c1-12) user-stories.md@sha256:$(sha256sum .spec/init/user-stories.md | cut -c1-12) database-schema.md@sha256:$(sha256sum .spec/init/database-schema.md | cut -c1-12) -->" ]
grep -Fq '**Conventions:**' "$F"
[ "$(grep -cE '^## Phase [0-9]+: ' "$F")" -ge 1 ]
# phase heading format is a hard contract — scripts/ralph.sh splits phases by regex
# (both loops must print nothing)
grep -E '^## Phase' "$F" | grep -vE '^## Phase [0-9]+: ' || true
grep -E '^### Phase' "$F" | grep -vE '^### Phase [0-9]+\.[0-9]+: ' || true
TASKS=$(grep -cE '^- \[[ x]\] \*\*Task:\*\*' "$F"); [ "$TASKS" -ge 1 ]
[ "$TASKS" -eq "$(grep -c '\*\*Acceptance criteria:\*\*' "$F")" ]   # every task has criteria
[ "$TASKS" -eq "$(grep -c '\*\*Traces:\*\*' "$F")" ]                # every task is traceable
# coverage: every story ID in the user-stories appendix appears in >=1 **Traces:** line
# (loop must print nothing; the ([^0-9]|$) guard keeps US-1.1 from matching US-1.10)
for id in $(grep -oE '^\| US-[0-9]+\.[0-9]+ ' .spec/init/user-stories.md | grep -oE 'US-[0-9]+\.[0-9]+' | sort -u); do
  grep -F '**Traces:**' "$F" | grep -qE "${id//./\\.}([^0-9]|$)" || echo "story not traced: $id"
done
# coverage: every table declared in the schema appears in >=1 task (loop must print nothing)
for t in $(grep -E '^Table [a-z0-9_]+ \{' .spec/init/database-schema.md | awk '{print $2}' | sort -u); do
  grep -qw "$t" "$F" || echo "table not covered: $t"
done
```

The two coverage loops are the enforcement of "cover everything": a story with no `**Traces:**` hit or a schema table mentioned nowhere in the plan means work was left unplanned. Fix by adding the missing tasks (or asking the developer) — never by deleting the story or the table from the upstream docs to silence the check.

### 6. Close out

After writing, report:

- The path written.
- Phase count, task count, and how many tasks are already `[x]`.
- Coverage: confirm every story ID and every schema table passed the mechanical coverage loops (green), or list what was added to close the gaps.
- The MVP cut line (which phase completes the first release).
- Self-checks: all green — list any check that initially failed and how it was fixed (Red → Green).
- Any open questions still needing the developer's decision.
