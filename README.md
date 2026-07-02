# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

### Option 3. Scaffold this fork into your repo (one shot, agent-driven)

This fork (`autonomous`) runs headless by default (auto-approves Codex requests
so unattended runs never stall) and ships an **agent-executable scaffolding
playbook** that sets up not just the engine but the whole repository contract —
workflow, `.codex` skills, Linear states/labels, secrets wiring, and launch. To
scaffold it into a project, point your agent at the playbook and your repo:

> Scaffold Symphony into `<path to my local repo>` by following
> https://github.com/gadkins/symphony/blob/autonomous/docs/scaffold-with-agent.md

Reference material:
- [`docs/scaffold-with-agent.md`](docs/scaffold-with-agent.md) — the do-it playbook (agent-facing).
- [`docs/repository-integration.md`](docs/repository-integration.md) — the why/where reference.
- [`examples/bootstrap.sh`](examples/bootstrap.sh) — toolchain/build/preflight/launch.
- [`examples/provision-linear.py`](examples/provision-linear.py) — idempotent Linear states + labels.

> [!WARNING]
> The permissive auto-approval in this fork bypasses Codex's human-in-the-loop
> approval step. It is intended for solo, trusted experiments and is gated behind
> the `--i-understand-that-this-will-be-running-without-the-usual-guardrails`
> flag. Rely on the target repo's GitHub protections for safety.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
