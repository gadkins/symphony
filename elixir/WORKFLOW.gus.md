---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "agent-core-91e4dedb5e2b"
  required_labels: []
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    case "$SOURCE_REPO_URL" in
      *github.com*|git@github.com:*|https://github.com/*)
        echo "Refusing non-local SOURCE_REPO_URL: $SOURCE_REPO_URL" >&2
        exit 1
        ;;
    esac
    git clone --depth 1 "$SOURCE_REPO_URL" .
    # Local-only guardrail: remove remote so push/fetch to upstream cannot happen.
    git remote remove origin || true
    # Trust repo-local mise config so Node/npm commands run in fresh workspaces.
    if command -v mise >/dev/null 2>&1; then
      mise trust "$PWD" || true
    fi
codex:
  # Use Node bin first in PATH so npx/codex avoid mise shim trust checks in fresh workspaces.
  # Force HTTP Responses transport (no websocket) to avoid repeated websocket 401 auth failures.
  command: test -n "$OPENAI_API_KEY" || { echo "OPENAI_API_KEY is missing in Symphony runtime env" >&2; exit 1; }; OPENAI_API_KEY="$OPENAI_API_KEY" PATH="/Users/grayson.adkins/.local/share/mise/installs/node/latest/bin:$PATH" /Users/grayson.adkins/.local/share/mise/installs/node/latest/bin/npx -y @openai/codex --disable responses_websockets --disable responses_websockets_v2 -c 'model_provider="openai_http"' -c 'model_providers.openai_http.name="OpenAI HTTPS only"' -c 'model_providers.openai_http.base_url="https://api.openai.com/v1"' -c 'model_providers.openai_http.wire_api="responses"' -c 'model_providers.openai_http.env_key="OPENAI_API_KEY"' -c 'model_providers.openai_http.supports_websockets=false' app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
agent:
  max_concurrent_agents: 1
  max_turns: 20
---

You are implementing the agent-core backlog in this Linear project.

Hard constraints:
- This is a throwaway local prototype effort.
- Never run `git push`.
- Never open pull requests.
- Keep all git remotes removed in workspace clones (`git remote remove origin`).
- Work directly in the workspace you were provisioned (the fresh clone at your current working directory). Do NOT run `git worktree add`, and never create files or worktrees outside your sandbox/workspace root — doing so triggers an approval prompt this headless runner cannot answer, which fails the run. Commit on a local branch within this workspace instead.
- Prefer small, verifiable checkpoints and update issue progress clearly.

Technical constraints:
- No automated tests required for this prototype unless explicitly requested in issue scope.
- Manual verification gates in ticket acceptance criteria are mandatory.
- Avoid broad refactors outside the issue scope.

Execution expectations:
- Complete the ticket end-to-end where feasible.
- If blocked, leave a concise blocker note on the issue with exact unblock action needed.
- Report exactly what changed, what was validated, and any remaining risks.
