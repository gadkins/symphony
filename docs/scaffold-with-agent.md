# Scaffold Symphony into your repository (agent playbook)

**Audience: a coding agent (Claude Code / Codex).** This is an imperative,
end-to-end playbook. A human points you at this file plus a target repository and
you carry out every step below, asking the human only for the inputs in Step 0
and for confirmation before any destructive action.

This is the `autonomous` fork's equivalent of "set Symphony up for my repo based
on `elixir/README.md`" — but it also scaffolds the **repository contract** (the
workflow, skills, Linear states, secrets wiring) that a bare engine setup leaves
out. For the *why/where* behind each file, read
[`repository-integration.md`](repository-integration.md); this doc is the *do-it*
version.

> **Posture reminder.** This fork defaults to **permissive auto-approval** so
> headless runs never stall (see `repository-integration.md` §4). Safety comes
> from the target repo's GitHub controls (draft PRs, branch protection, required
> checks/reviews, CODEOWNERS) plus workspace sandboxing — confirm those exist
> before pointing it at a shared repo.

---

## Step 0 — Collect inputs (ask the human for anything unknown)

| Input | Example | Used for |
|---|---|---|
| `FORK_DIR` | `~/symphony` (this repo checkout, `autonomous` branch) | building the engine, copying assets |
| `TARGET_REPO` | `~/my-service` (local clone) | where the scaffold files go |
| `GITHUB_REPO` | `git@github.com:acme/my-service.git` | the `after_create` clone URL |
| `LINEAR_API_KEY` | `lin_api_…` | provisioning + tracker access |
| `LINEAR_TEAM_KEY` | `ENG` | which Linear team to provision |
| `LINEAR_PROJECT_SLUG` | `my-service-abc123` | `tracker.project_slug` |
| Required secrets | `OPENAI_API_KEY`, service tokens | model access + app config |
| `SOURCE_ENV` (optional) | `~/my-service/.env` | seeding secrets into fresh clones |
| `E2E_ACCOUNT_SLUG` (optional) | `acme-test` | end-to-end probe target |
| Workflow style | `pr` (draft PR, human merges) vs `land` (auto-land) | which workflow to scaffold |

Confirm the target repo has (or create): a package manager, a test command, a
typecheck/lint command, and — if a Gus-style response can change — a dev-server +
health endpoint for end-to-end checks.

## Step 0.5 — Host tooling (required before Step 1)

Symphony runs workspace hooks via `sh -lc` and launches the **Codex CLI** as a
subprocess. Both must resolve correctly on the **login-shell PATH** used by that
process — not only in your interactive zsh/bash session.

Install and verify:

```bash
# Git: partial clones (--filter=blob:none) need Git ≥ 2.22. Prefer a current Homebrew git.
brew install git          # or: brew upgrade git
git --version             # expect ≥ 2.22

# Codex CLI: Symphony invokes `codex` directly (not `npx`).
brew install --cask codex # or: npm install -g @openai/codex  (Node ≥ 22)
codex --version

# Critical: verify the same binaries login shells see (this is what hooks/agents use).
sh -lc 'command -v git; git --version; command -v codex; codex --version'
```

**Common failure modes to catch here (do not skip):**

| Symptom | Likely cause |
|---|---|
| `error: unknown option 'filter=blob:none'` | An ancient `git` earlier on PATH (e.g. leftover `/usr/local/bin/git` 2.x from 2016) shadows Homebrew. Rename/remove it, or put `/opt/homebrew/bin` first in the hook. |
| `/bin/bash: codex: command not found` / `{:port_exit, 127}` | Codex not installed, or installed only under nvm/npm in a non-login PATH. Install via `brew install --cask codex` or ensure the npm global bin dir is on login PATH. |

Also ensure the scaffolded `after_create` hook exports a PATH that prefers modern tooling (see Step 3a template).

## Step 1 — Build/verify the Symphony engine

From `FORK_DIR/elixir` (pin the fork to a known commit for reproducibility):

```bash
cd "$FORK_DIR/elixir"
mise trust . && mise install
mise exec -- mix setup      # fetch deps
mise exec -- mix build      # build the escript (./bin/symphony)
```

Record the fork commit (`git -C "$FORK_DIR" rev-parse --short HEAD`) in the
target repo's `SETUP.md` so runs are reproducible.

## Step 2 — Inspect the target repo

Detect and note (you'll template these into the workflow): package manager
(`pnpm`/`npm`/`yarn`/`poetry`/`bundler`), the pinned language runtime, the
`typecheck`/`lint`/`test` commands, and the dev-server command + readiness URL.
If the repo uses `mise`, prefer running all tooling through `mise exec --` so the
agent uses the repo-pinned runtime, not a stray ambient one.

## Step 3 — Scaffold the repository contract into `TARGET_REPO`

Create each file **only if absent**; if present, diff and propose changes rather
than overwriting. Every path below is relative to `TARGET_REPO`.

### 3a. `WORKFLOW.<style>.md` (repo root)

Start from this template and fill the `<…>` placeholders using Steps 0–2. Trim
sections that don't apply (e.g. eval gates for a repo with no evals).

````md
---
tracker:
  kind: linear
  project_slug: "<LINEAR_PROJECT_SLUG>"
  required_labels: []
  active_states: [Todo, In Progress, Rework]      # Rework re-dispatches
  terminal_states: [Done, Canceled, Cancelled, Duplicate, Closed]
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT                   # MUST be outside the target repo
hooks:
  after_create: |
    set -eu
    # Prefer Homebrew (and user-local) bins — login shells often put stale
    # /usr/local/bin ahead of /opt/homebrew/bin via macOS path_helper.
    export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
    # Requires Git ≥ 2.22 (partial clone). Verified in Step 0.5.
    git clone --filter=blob:none <GITHUB_REPO> .
    # Seed gitignored secrets the fresh clone never receives (optional):
    SRC_ENV="<SOURCE_ENV>"
    if [ -n "$SRC_ENV" ] && [ -f "$SRC_ENV" ]; then
      [ -f .env ] || cp "$SRC_ENV" .env
      # Mirror into any sub-package that loads .env from its own cwd, if applicable.
    fi
    # Install deps with the repo-pinned toolchain:
    command -v mise >/dev/null 2>&1 && { mise trust "$PWD" || true; mise install || true; }
    <install command, e.g. mise exec -- pnpm install --frozen-lockfile>
agent:
  max_concurrent_agents: 3
  max_turns: 30
codex:
  # approval_policy MUST be "on-request" if org policy (/etc/codex/requirements.toml)
  # forbids "never". This fork auto-approves on-request, so headless runs don't stall.
  approval_policy: on-request
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
    writableRoots: []            # add caches/auth dirs your tools need to write
---

You are working autonomously on a Linear ticket `{{ issue.identifier }}` in `<repo>`.

## Operating principles
1. Unattended run; never ask a human mid-run. Stop only for a true external blocker.
2. Work only in the provided repository copy; no worktrees, no writes outside it.

## Status routing
- Todo -> move to In Progress, ensure a `## Codex Workpad` comment, start execution.
- In Progress -> continue from the workpad; re-verify any item marked blocked
  before concluding no work remains (blockers are provisional).
- Rework -> run the PR-feedback / human-feedback sweep; address every actionable
  comment; then post a confirmation comment (see below) before returning to
  Human Review.
- Human Review -> parked; do not act.

## Rework confirmation (required)
When the issue is in **Rework** after a human status move and/or Linear comment
naming the concern (merge conflicts, review feedback, missing evidence, etc.):

1. Treat that human feedback as the primary actionable input.
2. Address every item (or explicitly push back with rationale).
3. **Before** moving back to `Human Review`, create a **new top-level Linear
   comment** (`commentCreate`, not only a workpad `commentUpdate`) that confirms
   each raised concern was addressed, with brief evidence (commits, PR/MR URL,
   validation).
4. Keep the `## Codex Workpad` updated as usual. Ordinary Todo/In Progress runs
   still use the single workpad for progress and should not spam extra "done"
   comments — the confirmation comment is mandatory only for Rework handoffs.

## Execution flow
1. Determine repo state; sync with origin/main; write a plan + Validation checklist.
2. Implement in small commits, keeping the workpad current.
3. Validate (run through the repo's pinned toolchain):
   - <typecheck cmd>, <test cmd>, and any ticket-provided validation items.
   - End-to-end smoke (if a change can alter product behavior): boot a dev server
     on a free port and probe it (see bin/e2e-smoke). Record the probe + response.
   - Eval evidence (if responses can change): run the suite; paste metric deltas + URL.
   - Re-run anything a prior run marked blocked; don't carry a stale blocker forward.
4. Open a **draft** PR (or push to the ticket's named PR); fill the PR template,
   including a "How I tested" section with real evidence. Never merge.
5. Confirm CI is green. If this run was **Rework**, post the required confirmation
   comment first; then move the issue to `Human Review` and stop.
````

### 3b. `.codex/skills/linear/SKILL.md`

Copy from the fork so it's discoverable from the agent's cwd (the target repo):

```bash
mkdir -p "$TARGET_REPO/.codex/skills/linear"
cp "$FORK_DIR/.codex/skills/linear/SKILL.md" "$TARGET_REPO/.codex/skills/linear/SKILL.md"
```

> **Why here and not in the Symphony repo:** the agent runs in the *target repo's*
> clone, so skills must live under `TARGET_REPO/.codex/skills/`.

### 3c. `.symphony/SETUP.md`

Write a human runbook (prereqs, required secrets table with a vault reference,
the pinned fork commit, the Linear provisioning command, and the launch command).
Use the skeleton in `repository-integration.md` §2.3.

### 3d. `.symphony/provision-linear.py`

```bash
mkdir -p "$TARGET_REPO/.symphony"
cp "$FORK_DIR/examples/provision-linear.py" "$TARGET_REPO/.symphony/provision-linear.py"
chmod +x "$TARGET_REPO/.symphony/provision-linear.py"
```

### 3e. `bin/e2e-smoke` (only if the repo has a runnable server)

Stack-specific — the agent authors it from Step 2 details: allocate a free port,
boot the dev server, wait for the health endpoint, send one probe, capture
output under a gitignored dir, tear down. Add that dir to `.gitignore`.

### 3f. `.github/pull_request_template.md`

If absent, create one with `What / Why / How I tested` sections. If present,
leave it and rely on the workflow prompt to append a testing/evidence section.

### 3g. `mise.toml`

Pin the language runtime and any **external CLIs the workflow calls** so they
travel with the repo (this is how "commands that live outside Symphony" become
self-contained).

## Step 4 — Provision Linear

```bash
LINEAR_API_KEY="$LINEAR_API_KEY" "$TARGET_REPO/.symphony/provision-linear.py" \
  --team-key "$LINEAR_TEAM_KEY"        # add --dry-run first to preview
```

This ensures `Human Review` + `Rework` states and `symphony` / `ai-generated`
labels exist. Confirm `tracker.project_slug` in the workflow matches the project.

## Step 5 — Preflight secrets + host binaries

Verify every required variable is set (fail fast if not), and re-check the
login-shell tooling from Step 0.5:

```bash
for v in OPENAI_API_KEY LINEAR_API_KEY <service tokens…>; do
  [ -n "${!v:-}" ] || { echo "MISSING: $v"; exit 1; }
done
mkdir -p "${SYMPHONY_WORKSPACE_ROOT:-$HOME/symphony-workspaces}"

# Must pass under sh -lc (same PATH Symphony hooks/agents use):
sh -lc 'command -v codex >/dev/null || { echo "MISSING: codex on login PATH"; exit 1; }'
sh -lc 'git clone -h 2>&1 | grep -q -- "--filter" || { echo "MISSING: git --filter support (need ≥ 2.22)"; exit 1; }'
```

Prefer running [`examples/bootstrap.sh`](../examples/bootstrap.sh) — it enforces
these checks.

## Step 6 — Launch (and dry-run first)

Point at a **sandbox Linear project** for the first run. Use
[`examples/bootstrap.sh`](../examples/bootstrap.sh) (copy it to
`TARGET_REPO/.symphony/bootstrap.sh` and edit the CONFIG block), or launch
directly:

```bash
cd "$FORK_DIR/elixir"
OPENAI_API_KEY="$OPENAI_API_KEY" LINEAR_API_KEY="$LINEAR_API_KEY" \
SYMPHONY_WORKSPACE_ROOT="$HOME/symphony-workspaces" \
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  "$TARGET_REPO/WORKFLOW.<style>.md"
```

## Step 7 — Validate the scaffold

- Move one sandbox ticket to `Todo`; confirm Symphony dispatches it, the agent
  creates a workpad, opens a draft PR, and parks at `Human Review`.
- Confirm the `.codex/skills/linear` skill is picked up (the agent can create a
  follow-up issue) and that `after_create` seeded `.env` (no "undefined config").
- Only then repoint `tracker.project_slug` at the real project.

## Handoff report

When done, report: engine build result + pinned commit, the list of files
created/modified in `TARGET_REPO`, the Linear states/labels provisioned, the
preflight result, and the exact launch command. Do not merge anything.
