---
description: Read the project description and derive structured, testable user stories at .spec/init/user-stories.md
argument-hint: "[optional focus area or extra context]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, AskUserQuestion
---

# init:user-stories

You are helping a developer turn a **project description** into a set of **clear, testable user stories**. This document is the second artifact of the project spec. It builds directly on the project description and becomes the backlog the team plans and builds from.

Optional focus or extra context from the developer (may be empty):

```
$ARGUMENTS
```

## Your goal

Read the existing project description and produce a single document at **`.spec/init/user-stories.md`** that:

1. Identifies every **user type** (persona) the system serves.
2. Groups functionality into **feature areas**.
3. Writes **user stories** in the `As a / I want to / So that` form, each with concrete **acceptance criteria** and an **expected result**.
4. Assigns a **priority** to each story and tracks status in an appendix table.

## Process

### 1. Read the source of truth first

Before asking anything, read **`.spec/init/project-description.md`**. This is the input to this command.

- If the file is missing, stop and tell the developer to run `init:project-description` first.
- Extract from it: the user types, core concepts, core workflows, tech stack constraints, and the MVP boundary.
- Also scan any other files already under `.spec/` for decisions already made.

Match the **language** of the project description (write the stories in the same language the developer used).

### If the target file already exists (re-run)

Re-running this command must **update** the existing document, never rebuild it from scratch — `.spec` belongs to the developer, and manual edits there are decisions, not noise.

- Read the existing `.spec/init/user-stories.md` **before** interviewing. Every decision recorded in it (stories, criteria, priorities, exclusions) is source of truth.
- Interview only about **deltas**: workflows or concepts added to the description since, new gaps, contradictions. Never re-ask what the document already answers.
- Update via **Edit**, not a full rewrite. Preserve every existing `US-x.y` ID and feature-area number: a new story takes the next free ID in its area, a new area takes the next `## N.` at the end; never renumber. Update the appendix by appending rows — existing rows keep their IDs.
- A story or section the developer deleted stays deleted — restore it only if the developer explicitly confirms.

Line 3 of the existing file is its **input stamp** (see step 3). Verify it before interviewing:

```bash
# prints nothing when fresh; any output = that input changed after this document was generated
for pair in $(sed -n '3p' .spec/init/user-stories.md | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
  [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
    || echo "stale: ${pair%%@*} changed after this document was generated"
done
```

Any output → warn the developer ("input changed after this artifact was generated — review before proceeding") and focus the delta interview on what changed in that input. Warn and proceed; never block. A file without a line-3 stamp predates this mechanism — nothing to verify.

### 2. Interview to close gaps

Derive as many stories as you can directly from the description, then find what's undefined. Ask the developer only about gaps that change the shape or scope of the stories — do not interrogate on things the description already answers. Focus on:

- **Persona boundaries** — who can do what; overlaps and permissions.
- **MVP vs deferred** — which stories are in the first version; what is explicitly out.
- **Priority** — which flows are must-have (High) vs nice-to-have (Medium/Low).
- **Acceptance edge cases** — limits, states, failure paths that make a story testable.
- **Missing flows** — anything implied by the concepts/workflows but not yet a story.

Use `AskUserQuestion` for discrete decisions with clear options (e.g. priority, in/out of MVP). Ask real open questions in plain text when the answer is not a menu. Batch related questions; don't drip one at a time. When something stays undecided, mark it as an open question rather than inventing an answer.

### 3. Write the document

Write to `.spec/init/user-stories.md` (create the `.spec/init/` directories if missing). Use **exactly** this structure:

```markdown
# <Project Name> — User Stories

<!-- inputs: project-description.md@sha256:<first 12 chars> -->

## Overview

<1–2 paragraphs: what the product is and who it serves. Then a bullet list of user types.>

**User Types:**
- **<Persona>** - <one-line definition>
- ...

---

## 1. <Feature Area>

### US-1.1: <Short Story Title>
**As a** <persona>
**I want to** <capability>
**So that** <benefit>

**Acceptance Criteria:**
- [ ] <specific, testable condition>
- [ ] <specific, testable condition>
- [ ] ...

**Expected Result:** <the end state when the story is done>

---

### US-1.2: <Short Story Title>
...

## 2. <Feature Area>
...

## Appendix: User Story Status

| ID | Story | Priority | Status |
|----|-------|----------|--------|
| US-1.1 | <title> | High/Medium/Low | Pending |
| ... | ... | ... | ... |
```

Rules for the document:

- **Title** = project name + `— User Stories`.
- **Line 3** is the machine-owned **input stamp**: `<!-- inputs: project-description.md@sha256:<12 chars> -->`, the checksum being `sha256sum .spec/init/project-description.md | cut -c1-12` over the file as read in step 1. Refresh it on **every** run, including re-run Edits — downstream commands use it to detect drift. Never preserve a stale stamp as a "developer edit".
- Number feature areas (`## 1.`, `## 2.` …) and stories within them (`US-1.1`, `US-1.2` …). Keep IDs stable.
- Every story uses the full `As a / I want to / So that` triple, an **Acceptance Criteria** checkbox list, and an **Expected Result** line.
- Acceptance criteria must be **concrete and testable** — state limits, states, and failure paths (e.g. "reset link valid for 60 minutes", "image max size 5MB"), not vague intent.
- Cover every user type and every core workflow from the project description. No invented features — keep each story traceable to the description or a developer decision.
- The **appendix table** lists every story with its priority and status (`Pending` by default). Order roughly by priority.
- If gaps remain unresolved, add a short `## Open Questions` section before the appendix. Otherwise omit it.

### 4. Coverage check (workflows → stories)

Every numbered workflow in the project description must map to at least one story. List the workflows mechanically:

```bash
grep -E '^### [0-9]+\. ' .spec/init/project-description.md
```

For each workflow, name the story IDs that cover it. Only two outcomes are acceptable:

- **Covered** — at least one story ID.
- **Excluded** — the developer explicitly decided not to cover it. Record the reason; the decision must come from the interview, never assumed.

A workflow with no stories and no recorded decision is a gap: add the missing stories (or ask the developer) before closing out.

Build the coverage table for the close-out report:

| Workflow | Stories |
|----------|---------|
| 1. <name> | US-1.1, US-2.3 |
| 2. <name> | — excluded by developer: <reason> |

### 5. Self-checks (run until green)

After writing, run these checks. Any failure → fix the document via Edit and re-run until all pass. Never report completion with a failing check.

```bash
F=.spec/init/user-stories.md
test -f "$F"
head -1 "$F" | grep -qE '^# .+ — User Stories$'
# line 3 input stamp present and fresh
[ "$(sed -n '3p' "$F")" = "<!-- inputs: project-description.md@sha256:$(sha256sum .spec/init/project-description.md | cut -c1-12) -->" ]
grep -Fq '**User Types:**' "$F"
grep -Fq '## Appendix: User Story Status' "$F"
STORIES=$(grep -cE '^### US-[0-9]+\.[0-9]+:' "$F"); [ "$STORIES" -ge 1 ]
[ "$STORIES" -eq "$(grep -c '^\*\*As a\*\*' "$F")" ]                    # every story has the persona line
[ "$STORIES" -eq "$(grep -c '^\*\*Acceptance Criteria:\*\*' "$F")" ]    # every story has criteria
[ "$STORIES" -eq "$(grep -c '^\*\*Expected Result:\*\*' "$F")" ]        # every story has expected result
# body story IDs == appendix table IDs (diff must be empty)
diff <(grep -oE '^### US-[0-9]+\.[0-9]+' "$F" | sed 's/### //' | sort -u) \
     <(grep -oE '^\| US-[0-9]+\.[0-9]+ ' "$F" | grep -oE 'US-[0-9]+\.[0-9]+' | sort -u)
```

### 6. Close out

After writing, report:

- The path written.
- The count of stories and how many are High priority.
- The coverage table from step 4 (Workflow | Stories) — every workflow covered or explicitly excluded.
- Self-checks: all green — list any check that initially failed and how it was fixed (Red → Green).
- Any open questions still needing the developer's decision.
