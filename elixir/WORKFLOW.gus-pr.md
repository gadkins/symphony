---
# Phase 1 PR-producing workflow for the agent-core backlog.
#
# Posture: maximum autonomy up to (but not including) merge. Agents plan, code,
# test, push a branch, and open a DRAFT PR, then park the issue for human review.
# Merging stays a human action on GitHub; do NOT auto-merge in Phase 1.
#
# Safety lives in GitHub (branch protection + required checks + required reviews
# + CODEOWNERS), not in per-command Codex approvals. See the runbook notes at the
# bottom for the prerequisites this workflow assumes.
tracker:
  kind: linear
  # agent-core project. Point this at a sandbox project first if you want a dry run.
  project_slug: "agent-core-91e4dedb5e2b"
  required_labels: []
  # Human Review is intentionally NOT active: the agent parks there and waits for a
  # human to merge. Merging/land is intentionally absent (no auto-merge in Phase 1).
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
    - Closed
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  # Clone the real GitHub repo so origin exists for push + `gh pr create`.
  # Partial clone (blob:none) keeps full history for rebase/merge against origin/main
  # without downloading every blob up front. Do NOT remove origin here.
  after_create: |
    set -eu
    git clone --filter=blob:none git@github.com:Gusto/agent-core.git .
    # Seed local-only secrets. The fresh clone never receives agent-core's .env
    # (gitignored), so AI_PLATFORM_SERVICES__TOKEN / CONTEXT_RETRIEVAL_SERVICE__TOKEN /
    # MCP__TOKENS__* are missing and evals + e2e that hit live backends fail with
    # "<var> undefined". Copy the developer's .env from the source checkout. Config
    # loads .env from its own cwd with no parent walk, so mirror it into both the repo
    # root (bin/server) and each agent package that has an env cascade (evals run there).
    # Every destination is gitignored, so this can never leak into a commit.
    SRC_ENV=/Users/grayson.adkins/agent-core/.env
    if [ -f "$SRC_ENV" ]; then
      [ -f .env ] || cp "$SRC_ENV" .env
      for d in agents/*/; do
        if [ -f "${d}env.example" ] && [ ! -f "${d}.env" ]; then
          cp "$SRC_ENV" "${d}.env"
        fi
      done
    else
      echo "WARN: $SRC_ENV not found; evals/e2e needing live backend tokens will be blocked" >&2
    fi
    if command -v mise >/dev/null 2>&1; then
      mise trust "$PWD" || true
      mise install || true
    fi
    corepack enable 2>/dev/null || true
    # Run pnpm through mise so it uses agent-core's pinned Node (24.14.1), not a stray
    # ambient Node (a bare `pnpm install` here picked up v26 and failed engines check).
    mise exec -- pnpm install --frozen-lockfile || mise exec -- pnpm install
agent:
  # Start conservative while building trust; raise once you've watched a few cycles.
  # Independent (non-blocked) issues run in parallel up to this cap.
  max_concurrent_agents: 3
  max_turns: 30
codex:
  # HTTP-only transport to avoid websocket auth flakiness (mirrors WORKFLOW.gus.md).
  # approval_policy: on-request is REQUIRED — /etc/codex/requirements.toml (org-managed)
  # only allows ["on-request"]; "never" is rejected with a -32600 thread-settings error.
  # Headless runs cannot grant approvals, so any action needing one surfaces as blocked.
  # This workflow avoids that by working in-place (no worktrees / no writes outside the
  # workspace); blast radius is the per-issue clone + branch/PR, gated by GitHub.
  # Node is pinned to 24.14.1 (agent-core's engines.node) so the agent's pnpm / bin/server
  # / agent-chat-cli run on the repo-required Node, not a stray ambient v26.
  command: test -n "$OPENAI_API_KEY" || { echo "OPENAI_API_KEY is missing in Symphony runtime env" >&2; exit 1; }; OPENAI_API_KEY="$OPENAI_API_KEY" PATH="/Users/grayson.adkins/.local/share/mise/installs/node/24.14.1/bin:$PATH" /Users/grayson.adkins/.local/share/mise/installs/node/24.14.1/bin/npx -y @openai/codex --disable responses_websockets --disable responses_websockets_v2 -c 'model_provider="openai_http"' -c 'model_providers.openai_http.name="OpenAI HTTPS only"' -c 'model_providers.openai_http.base_url="https://api.openai.com/v1"' -c 'model_providers.openai_http.wire_api="responses"' -c 'model_providers.openai_http.env_key="OPENAI_API_KEY"' -c 'model_providers.openai_http.supports_websockets=false' app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
    # The per-issue workspace (cwd) is writable implicitly under workspaceWrite.
    # Add agent-chat-cli's config/auth dir so the CLI can read the cached staging
    # session cookie AND write conversation/refresh state during e2e runs without
    # tripping a sandbox denial. (Auth still cannot be *refreshed* headlessly; see
    # the e2e section in the prompt.)
    writableRoots:
      - /Users/grayson.adkins/.agent-chat-cli
---

You are working autonomously on a Linear ticket `{{ issue.identifier }}` in the Gusto `agent-core` repository.

{% if attempt %}
Continuation context:
- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed *and passing* investigation or validation unless it is needed for new code changes.
- **Exception — blocked items are not settled.** Any workpad item previously recorded as blocked (missing env/secrets, auth, a service that would not start, etc.) MUST be re-attempted this run before you re-park; the blocker may have been resolved externally between runs. See "Blocked-access escape hatch".
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Operating principles

1. This is an unattended orchestration session. Never ask a human to perform a follow-up action mid-run. Only stop early for a true external blocker (missing required auth/secrets/permissions you cannot resolve in-session).
2. Work only in the provided repository copy (your current working directory). Do not touch any other path, and never create git worktrees or write outside this workspace.
3. Your final message reports completed actions, what you validated, and any blockers. Do not include "next steps for the user".

## Hard constraints (Phase 1 — draft PR, human merges)

- **Never push to `main` and never merge.** Do not run `git push origin main`, `gh pr merge`, or enable auto-merge. Merging is a human action.
- **In new-PR mode, open the PR as a draft** (`gh pr create --draft`) and leave it as a draft; a human marks it ready and merges. (In append mode you push to the ticket's existing PR and never create one — see step 8.)
- **Never move the issue to `Done`.** `Done` is set automatically when the PR merges (via Linear's GitHub integration). Your terminal handoff state is `Human Review`.
- **Respect repository protections.** Do not attempt to bypass branch protection, required checks, or CODEOWNERS. If a required review path blocks you, that is expected — hand off to `Human Review`.
- **Stay in scope.** Implement only what the ticket asks. If you discover meaningful out-of-scope work, file a separate Linear issue (see "Follow-up issues") instead of expanding this one.
- **PR mode depends on the ticket.** *New-PR mode (default):* one branch per issue, created from `origin/main` — prefer the Linear-provided branch name (`{{ issue.branch_name }}`), otherwise `symphony/{{ issue.identifier }}` — and open a new draft PR. *Append mode:* if the ticket explicitly names an existing PR to push to (e.g. "push commits directly to PR #NNNN — do not open a new PR"), do NOT create a new PR or a new branch; follow the append-mode flow in step 8.

## Status routing

- `Backlog` -> not in scope for this workflow; do not modify. (Symphony will not dispatch it.)
- `Todo` -> move to `In Progress`, ensure a `## Codex Workpad` comment exists, then start execution. If the workpad is already a completed handoff except for items marked blocked, a human likely re-queued this ticket precisely so those blocked items get re-attempted — do that (see "Blocked-access escape hatch"), do not just re-audit git/PR and re-park. Dependencies are enforced upstream: Symphony will not have dispatched this ticket unless every issue that "blocks" it is already in a terminal state, so you may assume blockers are merged into `main`.
- `In Progress` -> continue execution from the current workpad. Before concluding no work remains, re-verify every item the workpad marks blocked (see "Blocked-access escape hatch"); a stale blocker is not a reason to re-park.
- `Rework` -> reviewer requested changes; run the rework flow.
- `Human Review` -> parked for a human; do not act (Symphony does not dispatch this state).

**PR mode check (do this while planning):** read the ticket for an explicit existing-PR instruction (e.g. "push commits directly to PR #NNNN — do not open a new PR", or a linked PR the ticket says to continue). If present, you are in **append mode** (step 8); otherwise **new-PR mode**. The ticket's instruction wins over the default "one branch, new draft PR" behavior.

## Execution flow (Todo / In Progress)

1. Determine repo state (`git status`, current branch, `HEAD`).
2. Find or create a single persistent `## Codex Workpad` Linear comment and treat it as the live plan/checklist. Keep it current; do not open extra summary comments.
3. Sync with latest `origin/main` before editing (fetch + merge/rebase) and record the resulting short SHA in the workpad `Notes`.
4. Write a hierarchical plan with explicit Acceptance Criteria and a Validation checklist. If the ticket includes a `Validation` / `Test Plan` / `Testing` section, mirror those as required (non-optional) checklist items.
5. Reproduce/confirm the current behavior before changing code when applicable, and note the signal.
6. Implement in small, logical commits. Keep the workpad checklist checked off as you go.
7. Validate. Required gates before handoff. **Run every Node/pnpm command through `mise exec --`** so it uses agent-core's pinned Node (24.14.1); a bare `pnpm`/`node` may resolve to a stray ambient version and fail the engines check. **If a prior run marked any validation item blocked, re-run it now — do not carry a stale blocked status forward (see "Blocked-access escape hatch").**
   - `mise exec -- pnpm typecheck`
   - `mise exec -- pnpm test` (scope to the affected package/workspace where possible)
   - Any ticket-provided validation items (treat a ticket `Validation` / `Test Plan` / `Testing` section as mandatory, non-optional).
   - **End-to-end smoke — REQUIRED whenever the diff touches prompts, tools, graph logic, or services (anything that can change a Gus response).** Each agent owns its own clone, so boot one server per agent on its **own dynamically-allocated free port** and target it with `agent-chat-cli -u` — never assume the default 3200 and never share a port across agents. Use the checked-in helper, which allocates a free port, boots a dedicated `--no-gateway` server, waits for readiness, sends the probe with `-u`, captures evidence, and tears everything down:
     ```bash
     mise exec -- bin/e2e-smoke "<a probe question that exercises THIS change>" kora-axle-works
     ```
     The response is echoed to stdout and saved under `.e2e-smoke-*/response.txt` (git-ignored); the server log sits beside it. The account slug (`kora-axle-works`) can also come from `$E2E_ACCOUNT_SLUG` if you omit the 2nd arg.

     If `bin/e2e-smoke` is not present in this checkout (older base), run the equivalent inline (writes only inside your workspace so it stays within the sandbox):
     ```bash
     E2E_DIR="$(mktemp -d "$PWD/.e2e-XXXXXX")"
     PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
     DD_TRACE_ENABLED=false mise exec -- bin/server --staging --no-gateway --port "$PORT" > "$E2E_DIR/server.log" 2>&1 &
     SERVER_PID=$!
     for i in $(seq 1 90); do curl -sf "http://localhost:$PORT/health-check/ready" >/dev/null 2>&1 && break; sleep 2; done
     mise exec -- agent-chat-cli -u "http://localhost:$PORT" -a "${E2E_ACCOUNT_SLUG:-kora-axle-works}" \
       -m "<a probe question that exercises THIS change>" | tee "$E2E_DIR/out.txt"
     kill "$SERVER_PID" 2>/dev/null || true
     ```
     Requirements/caveats: needs `agent-chat-cli` >= 0.8.0 (the `-u` flag; `mise install` in `after_create` provides it) and a valid cached staging session in `~/.agent-chat-cli`. Do not commit the `.e2e-smoke-*` / `.e2e-*` dirs or logs. If the server cannot boot, `agent-chat-cli` lacks `-u`, or auth is expired/unavailable, do **NOT** silently skip: record the exact failure (command + error) in the workpad and PR body and hand off to `Human Review`. Capture the probe question and the response snippet — they are required in the PR "How I tested" section.
   - **Eval evidence — REQUIRED whenever the change can affect Gus responses (prompts, tools, graph logic, retrieval, scorers).** Run the affected Braintrust suite (e.g. `cd agents/gus && mise exec -- pnpm eval <suite>`), and paste the key metric deltas vs. `main` plus the Braintrust run URL into the PR. If the ticket names specific suites/metrics (e.g. Correct Help Center Link), those are mandatory. Offline `pnpm eval` complements, and does not replace, the e2e smoke above.
   - Revert any temporary proof edits before committing.
8. Open the PR (or update the designated one):
   - **New-PR mode (default):** push the branch to `origin` and open a **draft** PR with `gh pr create --draft` and a clear title.
   - **Append mode (ticket names an existing PR):** check out that PR's branch (`gh pr checkout <NNNN>`), sync it with latest `origin/main` (fetch + rebase/merge), push your commits to that same branch, and do **NOT** run `gh pr create`. Leave the PR's draft/ready state as you found it, and add your validation evidence as a PR comment plus in the workpad.
   - **PR body format.** If the repo has a PR template (`.github/pull_request_template.md` or `.github/PULL_REQUEST_TEMPLATE/*.md`), follow it exactly, filling every section. Otherwise use this format and fill EVERY section (no empty sections, no leftover placeholder comments):
     ```md
     # What?

     ## Changes

     # Why?

     # How I tested
     ```
     **Test evidence is mandatory regardless of template.** If the repo template has no "How I tested" (or equivalent testing/validation) section, append one to the body. It must contain real evidence, not intentions: the commands run (`pnpm typecheck` / `pnpm test`), the e2e smoke probe question + response snippet (or the explicit reason it could not run), and — when the change can affect Gus responses — the eval metric deltas vs. `main` plus the Braintrust run URL. In append mode, put this same evidence in a PR comment.
   - Add labels `symphony` and `ai-generated` (create/add if missing).
   - Attach or link the PR URL on the Linear issue.
9. Confirm CI checks are triggered/green on the pushed commit. Address failures and re-push until green.
10. Update the workpad with final checklist status and validation evidence, then move the issue to `Human Review`. Stop.

## Rework flow

1. Treat `Rework` as an approach reset. Re-read the full issue and all PR/human comments.
2. Run the PR feedback sweep: gather top-level PR comments (`gh pr view --comments`), inline review comments (`gh api repos/Gusto/agent-core/pulls/<pr>/comments`), and review states (`gh pr view --json reviews`). Treat every actionable comment (human or bot) as blocking until addressed in code or answered with explicit, justified pushback on that thread.
3. Apply changes on the same branch/PR (or a fresh branch from `origin/main` if the prior PR was closed/merged), re-validate, push, and return the issue to `Human Review`.

## Follow-up issues (dependency-aware)

When you find necessary out-of-scope work, create a separate Linear issue instead of growing this one. It must have a clear title, description, and acceptance criteria, be placed in `Backlog`, be in the same project, link this issue as `related`, and use `blockedBy` when it depends on this issue. Expressing `blockedBy` is how sequencing is enforced: Symphony will not start a dependent issue until its blockers reach a terminal (merged) state.

Use the `linear` skill's "Create a follow-up issue in Backlog" recipe for the exact `issueCreate` + `issueRelationCreate` mutations (including how to resolve the `Backlog` state id and the correct `blocks` relation direction — there is no `blockedBy` enum). Filing these follow-ups is encouraged: they give the human a queue to review and triage, so prefer creating a well-scoped Backlog issue over dropping the observation.

## Blocked-access escape hatch

Only for missing required tools/auth/secrets that cannot be resolved in-session (GitHub auth is not a valid blocker until you have tried alternate auth and documented it). If truly blocked, record in the workpad: what is missing, why it blocks acceptance, and the exact human action needed to unblock; then move to `Human Review`.

**Blockers are provisional, not permanent.** A blocker recorded in a *previous* run is not a fact you may rely on. On every dispatch — including after a Symphony restart or a human bouncing the ticket back to `Todo`/`Rework` — you MUST actually re-execute each validation item the workpad marks blocked before trusting that status, because the environment may have changed between runs (e.g. secrets/env seeded into the workspace, auth refreshed, access granted). Never re-park at `Human Review` on a stale blocker you did not re-verify *this* session. If the re-attempt now passes, flip the item to done, record the evidence, and continue the flow (run remaining gates, update the PR). Only if it fails again do you re-record the blocker — with the fresh command and exact error from this run — and hand off.

## Workpad template

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan
- [ ] 1. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria
- [ ] Criterion 1

### Validation
- [ ] `pnpm typecheck`
- [ ] `pnpm test` (affected scope)
- [ ] ticket-provided validation items

### Notes
- <short progress note with timestamp; include origin/main sync SHA>

### Confusions
- <only when something was genuinely unclear during execution>
````
