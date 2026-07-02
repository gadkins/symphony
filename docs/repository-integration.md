# Making a Repository "Symphony-Ready" (Linear-driven PR workflow)

This guide describes how to lay out a **target repository** so that Symphony can
pick up work from a Linear board and drive it to a pull request autonomously. It
is deliberately generic: replace `<your-repo>`, `<workflow-name>`, and the slugs
with your own values. A concrete, working example (Gusto's `agent-core`) is
called out in side-notes where it helps.

> **Scope.** This document covers the *repository contract* — the files that live
> in the repo the agent works in. It does **not** cover building the Symphony
> engine itself; see `elixir/README.md` for that. The customized engine in this
> fork defaults to permissive auto-approval (see
> [Engine posture](#engine-posture-this-fork) below).

---

## 1. The core principle: co-locate everything the agent needs

Two design rules drive the layout:

1. **The workflow file is repository-owned and version-controlled.** Per the
   Symphony spec (`SPEC.md` §5.1–§5.2), a `WORKFLOW.*.md` is discovered either
   from an explicit path passed at launch or as `WORKFLOW.md` in the working
   directory, and it "SHOULD be self-contained enough to describe and run …
   without requiring out-of-band service-specific configuration."

2. **Skills and docs must live where the agent can see them.** Symphony launches
   the coding agent (Codex) with its working directory set to *your repo's clone*.
   Skills, plans, and guidance are discovered **relative to that working
   directory** — so they belong in the target repo, not inside the Symphony
   engine tree. This mirrors the "harness engineering" practice of keeping
   plans/skills/docs *versioned and co-located so agents operate without relying
   on external context* (progressive disclosure).

> ⚠️ **Common mistake (learned the hard way).** Putting an agent-facing skill
> (e.g. a `linear` skill) under the *Symphony* repo's `.codex/skills/` does **not**
> make it available to the agent, because the agent's working directory is the
> *target repo* clone. Agent-facing skills must live in **`<your-repo>/.codex/skills/`**.
> (Engine-only skills that Symphony uses while operating on *itself* — commit,
> push, land, etc. — stay in the Symphony repo.)

---

## 2. Recommended repository layout

```text
<your-repo>/
├── WORKFLOW.<workflow-name>.md      # Symphony workflow: front matter (config) + prompt body
├── .codex/
│   └── skills/
│       └── linear/
│           └── SKILL.md             # agent-facing skill(s): must be discoverable from repo cwd
├── .symphony/
│   ├── SETUP.md                     # human runbook: prereqs, secrets, Linear provisioning, launch
│   └── provision-linear.(py|ts|sh)  # idempotent Linear setup (states + labels)  [optional]
├── bin/
│   └── e2e-smoke                    # repo-specific end-to-end test helper (optional but recommended)
├── .github/
│   └── pull_request_template.md     # PR body format the workflow fills in
├── mise.toml                        # pinned toolchain + external CLIs (e.g. agent-chat-cli)
└── … your project …
```

You do not need every file — but this is the full set that makes a repo fully
self-serve. Below, each one and *where it lives and why*.

### 2.1 `WORKFLOW.<workflow-name>.md` — the workflow (repo root)

- **Where:** repo root (or anywhere, as long as you pass the path at launch).
- **What:** YAML front matter (tracker selection, `workspace`, `hooks`, `codex`
  and `agent` config) followed by a Markdown prompt body that instructs the
  agent. See `SPEC.md` §5.3 for the front-matter schema.
- **Why here:** it is the entry point Symphony reads; keeping it in the repo means
  it is versioned alongside the code it drives and reviewed like any other change.
- **Naming:** use a suffix per intent — e.g. `WORKFLOW.pr.md` (open a PR, human
  merges) vs. `WORKFLOW.land.md` (auto-land). One repo can hold several.

> **Example (`agent-core`):** `WORKFLOW.gus-pr.md` — a Phase-1 "draft PR, human
> merges" workflow whose `after_create` hook clones the repo, seeds a local
> `.env`, and runs `pnpm install`, and whose prompt enforces typecheck/test/e2e
> and Braintrust eval evidence before handing off to a `Human Review` state.
> Complete, working copies of this workflow and its companion live on the **`gus`
> branch** of this fork (kept off `autonomous` so the default branch stays
> generic); use them as a concrete reference to adapt for your own repo.

### 2.2 `.codex/skills/<skill>/SKILL.md` — agent-facing skills

- **Where:** `<your-repo>/.codex/skills/` (discoverable from the agent's cwd).
- **What:** reusable, prescriptive recipes the agent invokes during a run — e.g. a
  `linear` skill with the exact GraphQL to create a follow-up issue, resolve a
  `Backlog` state id, or move an issue between states.
- **Why here:** the agent runs *in this repo's clone*; skills are resolved from
  there. See the warning in §1.

### 2.3 `.symphony/SETUP.md` — the human runbook

- **Where:** `<your-repo>/.symphony/SETUP.md` (a `.symphony/` dir keeps harness
  glue out of your source tree while staying versioned).
- **What:** everything a human needs before the first run. A skeleton:

  ```md
  # Symphony setup for <your-repo>

  ## Prerequisites
  - mise (toolchain manager), Codex CLI, gh (authenticated), git
  - A built Symphony engine (see the Symphony repo's elixir/README.md), pinned to <version/commit>

  ## Required secrets / environment
  | Variable            | Where to get it            | Notes                         |
  |---------------------|----------------------------|-------------------------------|
  | OPENAI_API_KEY      | <vault>                    | Codex model access            |
  | LINEAR_API_KEY      | Linear → Settings → API    | Tracker read/write            |
  | <SERVICE>__TOKEN    | <1Password vault>          | Needed by evals/e2e (if any)  |

  Never commit secrets. If your workflow's `after_create` hook seeds a local
  `.env`, point it at a developer checkout or a vault fetch — the destination
  must be gitignored.

  ## Linear provisioning
  Run `.symphony/provision-linear.<ext>` (idempotent). It ensures the workflow
  states and labels your workflow expects exist:
  - States: `Todo`, `In Progress`, plus custom handoff states `Human Review`
    (parked; NOT in `active_states`) and `Rework` (reviewer-requested changes;
    IN `active_states` so Symphony re-dispatches).
  - Labels: e.g. `symphony`, `ai-generated`.
  - Confirm the project slug matches `tracker.project_slug` in your workflow.

  ## Launch
  <the repeatable launch command — see bootstrap.sh>
  ```

- **Why here:** it is the one file a new colleague opens first; keeping it in the
  repo makes onboarding `git clone` + read.

### 2.4 `bin/<e2e helper>` — repo-specific test helper (optional)

- **Where:** your repo's `bin/`.
- **What:** a script the workflow calls to prove the change end-to-end (boot a
  server on a free port, send a probe, capture evidence, tear down). This is
  inherently project-specific, so it lives with the project.
- **Why not in Symphony:** the engine is language/stack agnostic; anything that
  knows how to run *your* app belongs in *your* repo.

> **Example (`agent-core`):** `bin/e2e-smoke` boots a dedicated dev server on a
> dynamically-allocated port and drives it via the released `agent-chat-cli -u`.

### 2.5 `.github/pull_request_template.md` — PR body format

- **Where:** standard GitHub location in your repo.
- **What:** the sections the workflow fills (What / Why / How I tested / evidence).
- **Why here:** GitHub reads it from the repo; the workflow prompt is told to
  honor an existing template and append a testing/evidence section if missing.

### 2.6 `mise.toml` — pinned toolchain and external CLIs

- **Where:** repo root.
- **What:** pin the language runtime and any **external commands the workflow
  depends on** (so "commands that live outside Symphony" travel with the repo).
- **Why here:** reproducibility — a colleague gets identical tool versions.

> **Example (`agent-core`):** pins `node = "24.14.1"` and
> `"github:Gusto/agent-chat-cli" = "0.8.0"` so the `-u` flag used by `bin/e2e-smoke`
> is always present.

---

## 3. What stays in the Symphony (engine) repo — not your project repo

Keep the **engine** as a pinned external dependency, not vendored per project:

- The Elixir/other reference implementation and any engine patches (e.g. approval
  policy behavior — see [Engine posture](#engine-posture-this-fork)).
- Engine-only Codex skills used when Symphony operates on *itself*
  (`commit`, `push`, `land`, `pull`, `debug`).

Pin a specific Symphony **version/commit** in your `SETUP.md`/bootstrap so runs
are reproducible. Upgrade deliberately.

---

## 4. Engine posture (this fork) {#engine-posture-this-fork}

This fork (`gadkins/symphony`) defaults to **permissive auto-approval** so
headless runs never stall on an approval prompt:

- `elixir/lib/symphony_elixir/codex/app_server.ex` auto-approves Codex requests
  under both `never` **and** `on-request` approval policies (upstream auto-approves
  only `never`), and replies with the `accept` decision that current Codex builds
  expect.
- This intentionally **bypasses the human-in-the-loop approval control** and is
  appropriate only for a solo, trusted, "guardrails-off" experiment. It is still
  gated behind Symphony's `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
  launch flag. Do not point it at a shared/production repo without understanding
  this trade-off.

Safety in this posture comes from the *destination* controls instead: draft PRs,
branch protection, required CI checks, required reviews, and CODEOWNERS on the
target repo — plus workspace sandboxing (`workspace-write`).

---

## 5. Quick checklist to make any repo Symphony-ready

- [ ] Add `WORKFLOW.<name>.md` at the repo root (front matter + prompt).
- [ ] Put agent-facing skills in `<repo>/.codex/skills/` (NOT in the Symphony repo).
- [ ] Add `.symphony/SETUP.md` (prereqs, secrets, Linear provisioning, launch).
- [ ] Add `.symphony/provision-linear.*` (states `Human Review`/`Rework`, labels).
- [ ] Add a `bin/` e2e helper if the workflow requires end-to-end proof.
- [ ] Add/confirm `.github/pull_request_template.md`.
- [ ] Pin toolchain + external CLIs in `mise.toml`.
- [ ] Pin the Symphony engine version/commit in `SETUP.md`.
- [ ] Provision Linear: states, labels, project slug, API key.
- [ ] Provide secrets via a vault; keep any seeded `.env` gitignored.

---

## 6. Example bootstrap

An illustrative, adapt-me bootstrap that ties the above together lives at
[`examples/bootstrap.sh`](../examples/bootstrap.sh) in this repo. It installs the
toolchain, builds the pinned engine, preflights required env vars, optionally
provisions Linear, and prints the repeatable launch command. Copy it into your
repo's `.symphony/bootstrap.sh` and edit the variables at the top.
