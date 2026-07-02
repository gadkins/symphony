#!/usr/bin/env bash
#
# examples/bootstrap.sh — illustrative bootstrap for running Symphony against a
# target repository with a Linear-driven, PR-producing workflow.
#
# This is an EXAMPLE. Copy it into your repo as `.symphony/bootstrap.sh` and edit
# the CONFIG block below. It is intentionally conservative: it validates
# prerequisites and prints the launch command rather than launching for you, so
# you can review before running an autonomous agent.
#
# See docs/repository-integration.md for the repository layout this assumes.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — edit these for your repo
# ─────────────────────────────────────────────────────────────────────────────

# Path to the Symphony engine checkout (this fork), built per elixir/README.md.
SYMPHONY_DIR="${SYMPHONY_DIR:-$HOME/symphony/elixir}"

# Pin the engine to a known-good commit/tag for reproducibility (empty = skip check).
SYMPHONY_PIN="${SYMPHONY_PIN:-}"

# Your target repo's workflow file (path can be absolute or relative to the repo).
WORKFLOW_FILE="${WORKFLOW_FILE:-$PWD/WORKFLOW.pr.md}"

# Where Symphony creates per-issue workspaces (must NOT be inside the target repo).
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/symphony-workspaces}"

# Symphony HTTP dashboard port.
PORT="${PORT:-4000}"

# Required environment variables (names only; values come from your shell/vault).
# Add any repo-specific service tokens your evals/e2e need.
REQUIRED_ENV=(
  OPENAI_API_KEY
  LINEAR_API_KEY
  # e.g. AI_PLATFORM_SERVICES__TOKEN  CONTEXT_RETRIEVAL_SERVICE__TOKEN
)

# Optional: an idempotent Linear provisioning script in your repo (states/labels).
PROVISION_LINEAR="${PROVISION_LINEAR:-$PWD/.symphony/provision-linear.sh}"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[bootstrap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
log "Checking prerequisites…"
have mise || die "mise not found — install it first (toolchain manager)."
have git  || die "git not found."
have gh   || log "WARN: gh (GitHub CLI) not found; the workflow needs it to open PRs."
have npx  || log "WARN: npx not found; Codex is usually run via 'npx @openai/codex'."
[ -d "$SYMPHONY_DIR" ] || die "SYMPHONY_DIR not found: $SYMPHONY_DIR"
[ -f "$WORKFLOW_FILE" ] || die "WORKFLOW_FILE not found: $WORKFLOW_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Pin check (optional) + build the engine
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$SYMPHONY_PIN" ]; then
  current="$(git -C "$SYMPHONY_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  case "$current" in
    "$SYMPHONY_PIN"*) : ;;
    *) log "WARN: Symphony at $current, expected pin $SYMPHONY_PIN. Checkout the pinned rev for reproducibility." ;;
  esac
fi

log "Installing toolchain + building the engine (mise install && mix setup && mix build)…"
( cd "$SYMPHONY_DIR" \
    && mise trust . >/dev/null 2>&1 || true \
    && mise install \
    && mise exec -- mix setup \
    && mise exec -- mix build )

# ─────────────────────────────────────────────────────────────────────────────
# 3. Preflight: required environment
# ─────────────────────────────────────────────────────────────────────────────
log "Preflighting required environment variables…"
missing=()
for v in "${REQUIRED_ENV[@]}"; do
  [ -n "${!v:-}" ] || missing+=("$v")
done
if [ "${#missing[@]}" -gt 0 ]; then
  die "Missing required env vars: ${missing[*]} (set them or source your vault first)."
fi
mkdir -p "$WORKSPACE_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# 4. Provision Linear (optional, idempotent)
# ─────────────────────────────────────────────────────────────────────────────
if [ -x "$PROVISION_LINEAR" ]; then
  log "Provisioning Linear (states/labels) via $PROVISION_LINEAR…"
  "$PROVISION_LINEAR"
else
  log "No executable provision-linear script at $PROVISION_LINEAR — ensure states"
  log "  'Human Review' (parked) and 'Rework' (re-dispatched) and labels exist manually."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Print the repeatable launch command
# ─────────────────────────────────────────────────────────────────────────────
log "Setup complete. Launch Symphony with:"
cat <<LAUNCH

  cd "$SYMPHONY_DIR" \\
  $(for v in "${REQUIRED_ENV[@]}"; do printf '%s="$%s" \\\n  ' "$v" "$v"; done)SYMPHONY_WORKSPACE_ROOT="$WORKSPACE_ROOT" \\
  mise exec -- ./bin/symphony \\
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \\
    --port $PORT \\
    "$WORKFLOW_FILE"

LAUNCH
