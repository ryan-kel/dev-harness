# dev-harness

A multi-agent development harness that chains four Claude Code CLI calls to analyze, plan, build, and QA code changes — autonomously.

Inspired by the harness pattern described in [Designing Harnesses for Long-Running LLM Agents](https://www.anthropic.com/engineering/harness-design-long-running-apps) on the Anthropic engineering blog.

## What this does

`harness.sh` orchestrates four specialized Claude agents in sequence:

| Phase | Agent | Output | Purpose |
|-------|-------|--------|---------|
| 1 | **Structurer** | `structure.md` | Explores the repo, maps relevant files, detects patterns |
| 2 | **Planner** | `plan.md` | Produces a step-by-step implementation plan |
| 3 | **Builder** | `build-result.md` | Executes the plan — writes code, runs tests |
| 4 | **QA** | `qa-report.md` | Reviews all changes, fixes issues, gives a pass/fail verdict |

Each agent reads the artifacts from previous phases and writes its own. All artifacts live in `.harness/`.

## Requirements

- **Claude Code CLI** — installed and authenticated (`claude` command available in your shell)
- **Max plan** (recommended) — the full pipeline makes 4 long-context API calls; Max gives the headroom for large codebases
- **Bash 4+**

## Quick start

```bash
# 1. Copy harness.sh into your project root
cp /path/to/dev-harness/harness.sh /your/project/

# 2. (Optional) Open it in Claude Code and tailor the prompts
#    to your project's specific conventions

# 3. Run it
./harness.sh "Add rate limiting middleware to all API endpoints"
```

## Commands

### Full pipeline (all 4 phases)

```bash
./harness.sh "Your task description"
```

### Plan only (Structurer + Planner, no code changes)

```bash
./harness.sh --plan-only "Refactor auth to use OAuth2"
```

Review `.harness/plan.md`, then continue:

```bash
./harness.sh --skip-plan
```

### Skip planning (use existing plan)

```bash
./harness.sh --skip-plan "Continue from existing plan"
```

### Builder only

```bash
./harness.sh --builder-only "Build from the current plan"
```

### QA only

```bash
./harness.sh --qa-only
```

### Clean up artifacts

```bash
./harness.sh --clean
```

## Typical workflows

### New feature

```bash
# Start with a plan to review before committing to code changes
./harness.sh --plan-only "Add WebSocket support for real-time notifications"

# Review the plan
cat .harness/plan.md

# If the plan looks good, build and QA
./harness.sh --skip-plan

# Check the QA report
cat .harness/qa-report.md
```

### Bug fixing

```bash
# Full pipeline — the structurer will find relevant code,
# the planner will identify the root cause, the builder will fix it
./harness.sh "Fix: users can bypass email verification by replaying the token"
```

### Pre-deployment review

```bash
# Run QA only against the current state of the codebase
./harness.sh --qa-only
```

### Background runs

```bash
# Run the full pipeline in the background
nohup ./harness.sh "Migrate from REST to GraphQL" > /dev/null 2>&1 &

# Check progress
tail -f .harness/run.log
```

### Iterative refinement

```bash
# Builder made mistakes? Run QA to fix them
./harness.sh --qa-only

# Still not right? Re-run builder with the same plan
./harness.sh --builder-only

# QA again
./harness.sh --qa-only
```

## How to adapt for a new project

The harness auto-detects your stack by reading:

- **CLAUDE.md** — project-specific guidance (conventions, build commands, architecture notes)
- **README.md** — general project context
- **Config files** — `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, etc.
- **Directory listing** — top-level file/folder overview

**For best results:**

1. **Have a CLAUDE.md** in your project root. This is the single most impactful thing you can do. Include build/test commands, architectural decisions, coding conventions, and anything a new developer would need to know.

2. **Tailor the prompts** (optional). Open `harness.sh` and edit the prompt templates in each `run_*` function to include project-specific instructions. For example, if your project has a specific testing pattern, add that to the Builder and QA prompts.

3. **Run `--plan-only` first** to see if the Structurer and Planner produce sensible output for your codebase. Adjust prompts if needed.

## How it works under the hood

```
./harness.sh "task"
    │
    ├── Creates .harness/ directory
    ├── Builds CODEBASE_PREAMBLE (auto-detects stack)
    │
    ├── Phase 1: claude -p --dangerously-skip-permissions "<structurer prompt>"
    │   └── Writes .harness/structure.md
    │
    ├── Phase 2: claude -p --dangerously-skip-permissions "<planner prompt>"
    │   ├── Reads: CODEBASE_PREAMBLE + structure.md
    │   └── Writes .harness/plan.md
    │
    ├── Phase 3: claude -p --dangerously-skip-permissions "<builder prompt>"
    │   ├── Reads: CODEBASE_PREAMBLE + structure.md + plan.md
    │   └── Writes .harness/build-result.md (also modifies your code!)
    │
    └── Phase 4: claude -p --dangerously-skip-permissions "<qa prompt>"
        ├── Reads: CODEBASE_PREAMBLE + structure.md + plan.md + build-result.md
        └── Writes .harness/qa-report.md (may also fix code)
```

Each `claude -p` call runs with `--dangerously-skip-permissions` so agents can read/write files, run tests, and execute build commands without interactive prompts. This is what makes unattended operation possible.

The task description is saved to `.harness/task.txt` so that `--skip-plan`, `--builder-only`, and `--qa-only` can reference it without you re-typing it.

## Cost and rate limit awareness

- **Each full run = 4 Claude API calls**, each potentially using significant context (codebase preamble + prior artifacts + the agent's own exploration).
- On large codebases, a single full run can consume substantial tokens. Use `--plan-only` to preview before committing to the full pipeline.
- **Rate limits**: If you hit rate limits, the `claude -p` call will fail and the harness will stop. Wait and re-run with `--skip-plan` or `--builder-only` to resume where you left off.
- **Max plan recommended**: The Builder and QA agents in particular can generate long outputs and need room for tool calls. Max gives you the most headroom.

## Tips

- **Start with `--plan-only`** until you trust the harness on your codebase. Review the plan before letting the Builder loose.
- **Commit before running** so you can easily `git diff` or `git reset` if the Builder produces unwanted changes.
- **Use CLAUDE.md** — a well-written CLAUDE.md dramatically improves all four agents' understanding of your project.
- **Check `qa-report.md`** — the QA agent gives a PASS/FAIL verdict. If it says FAIL, the issues section tells you what still needs attention.
- **Run iteratively** — use `--builder-only` and `--qa-only` to re-run individual phases as needed.
- **Background runs** — use `nohup` for long tasks and `tail -f .harness/run.log` to watch progress.
- **Keep `.harness/` out of commits** — the artifacts are working state, not source code. The included `.gitignore` handles this.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `claude: command not found` | Install Claude Code CLI and ensure it's on your PATH |
| Agent fails mid-run | Check `.harness/run.log` for errors. Resume with `--skip-plan` or `--builder-only` |
| Plan looks wrong | Edit `.harness/plan.md` manually, then `--skip-plan` |
| Builder made bad changes | `git checkout .` to reset, adjust the plan, re-run `--builder-only` |
| Rate limited | Wait a few minutes, resume with the appropriate `--skip-*` flag |
| Agents don't understand your project | Add or improve your `CLAUDE.md` file |
| QA says FAIL | Read the issues section in `qa-report.md` — fix manually or re-run `--qa-only` |
| Harness hangs | Claude CLI may be waiting for input — ensure `--dangerously-skip-permissions` is set (it is by default) |

## License

MIT
