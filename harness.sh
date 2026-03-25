#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-harness: Multi-agent development harness using Claude Code CLI
# Chains 4 agents: Structurer -> Planner -> Builder -> QA
# Communication via markdown artifacts in .harness/
# =============================================================================

HARNESS_DIR=".harness"
HISTORY_FILE="$HARNESS_DIR/history.log"
LOG_FILE="$HARNESS_DIR/run.log"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

# --- Colors & output helpers -------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}  ✓${NC}  $*"; }
warn()  { echo -e "${YELLOW}  !${NC}  $*"; }
err()   { echo -e "${RED}  ✗${NC}  $*" >&2; }
phase() { echo -e "\n${BOLD}${CYAN}════════ $* ════════${NC}\n"; }
dim()   { echo -e "${DIM}$*${NC}"; }

log() {
  local msg="[$(date +"%H:%M:%S")] $*"
  echo "$msg" >> "$LOG_FILE"
}

# --- Usage -------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: ./harness.sh [OPTIONS] <task-description>

Options:
  --plan-only       Run Structurer + Planner only (no code changes)
  --skip-plan       Skip Structurer + Planner, jump to Builder using existing plan
  --builder-only    Run only the Builder phase
  --qa-only         Run only the QA phase against current state
  --quiet           Suppress live agent output (only save to files)
  --clean           Remove .harness/ directory and exit
  -h, --help        Show this help message

Examples:
  ./harness.sh "Add user authentication with JWT tokens"
  ./harness.sh --plan-only "Refactor the database layer to use connection pooling"
  ./harness.sh --skip-plan "Continue building from existing plan"
  ./harness.sh --qa-only
  ./harness.sh --clean
USAGE
  exit 0
}

# --- Arg parsing -------------------------------------------------------------
PLAN_ONLY=false
SKIP_PLAN=false
BUILDER_ONLY=false
QA_ONLY=false
CLEAN=false
QUIET=false
TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-only)     PLAN_ONLY=true; shift ;;
    --skip-plan)     SKIP_PLAN=true; shift ;;
    --builder-only)  BUILDER_ONLY=true; shift ;;
    --qa-only)       QA_ONLY=true; shift ;;
    --quiet)         QUIET=true; shift ;;
    --clean)         CLEAN=true; shift ;;
    -h|--help)       usage ;;
    -*)              err "Unknown option: $1"; usage ;;
    *)               TASK="$1"; shift ;;
  esac
done

# --- Clean -------------------------------------------------------------------
if $CLEAN; then
  if [[ -d "$HARNESS_DIR" ]]; then
    rm -rf "$HARNESS_DIR"
    ok "Removed $HARNESS_DIR"
  else
    info "Nothing to clean — $HARNESS_DIR does not exist."
  fi
  exit 0
fi

# --- Validate claude CLI ----------------------------------------------------
if ! command -v claude &>/dev/null; then
  err "Claude Code CLI not found. Install it first: https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi

# --- History helpers ---------------------------------------------------------
history_add() {
  mkdir -p "$HARNESS_DIR"
  echo "$(date +"%Y-%m-%d %H:%M") | $1 | $2" >> "$HISTORY_FILE"
}

history_show() {
  if [[ -f "$HISTORY_FILE" ]]; then
    echo ""
    echo -e "  ${BOLD}Recent tasks${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────${NC}"
    tail -10 "$HISTORY_FILE" | nl -ba -w2 -s'  ' | while IFS= read -r line; do
      echo -e "  ${DIM}$line${NC}"
    done
    echo ""
  else
    dim "  No task history yet."
    echo ""
  fi
}

# --- Artifact status ---------------------------------------------------------
artifact_status() {
  local file="$1"
  local label="$2"
  if [[ -f "$file" ]]; then
    local size
    size=$(wc -c < "$file" | tr -d ' ')
    local modified
    modified=$(date -r "$file" +"%H:%M" 2>/dev/null || stat -c '%y' "$file" 2>/dev/null | cut -d. -f1)
    echo -e "    ${GREEN}●${NC} $label ${DIM}(${size}B, $modified)${NC}"
  else
    echo -e "    ${DIM}○ $label${NC}"
  fi
}

show_status() {
  echo ""
  echo -e "  ${BOLD}Artifacts${NC}"
  artifact_status "$HARNESS_DIR/structure.md"    "structure.md"
  artifact_status "$HARNESS_DIR/plan.md"         "plan.md"
  artifact_status "$HARNESS_DIR/build-result.md" "build-result.md"
  artifact_status "$HARNESS_DIR/qa-report.md"    "qa-report.md"
  echo ""
  if [[ -f "$HARNESS_DIR/task.txt" ]]; then
    echo -e "  ${BOLD}Last task:${NC} ${DIM}$(cat "$HARNESS_DIR/task.txt")${NC}"
    echo ""
  fi
}

# --- Banner ------------------------------------------------------------------
show_banner() {
  echo ""
  echo -e "  ${BOLD}${CYAN}┌─────────────────────────────────────┐${NC}"
  echo -e "  ${BOLD}${CYAN}│${NC}   ${BOLD}dev-harness${NC}  ${DIM}multi-agent pipeline${NC}  ${BOLD}${CYAN}│${NC}"
  echo -e "  ${BOLD}${CYAN}└─────────────────────────────────────┘${NC}"
  echo -e "  ${DIM}$(basename "$(pwd)")${NC}"
}

# --- Interactive mode --------------------------------------------------------
run_interactive() {
  show_banner
  show_status

  while true; do
    echo -e "  ${BOLD}What do you want to do?${NC}"
    echo ""
    echo -e "    ${BOLD}1${NC}  New task            ${DIM}full pipeline${NC}"
    echo -e "    ${BOLD}2${NC}  Plan only           ${DIM}structure + plan, no code changes${NC}"
    echo -e "    ${BOLD}3${NC}  Build from plan     ${DIM}execute existing plan${NC}"
    echo -e "    ${BOLD}4${NC}  QA only             ${DIM}review current changes${NC}"
    echo -e "    ${BOLD}5${NC}  View artifact        ${DIM}read an output file${NC}"
    echo -e "    ${BOLD}6${NC}  History             ${DIM}past tasks${NC}"
    echo -e "    ${BOLD}7${NC}  Clean               ${DIM}wipe .harness/${NC}"
    echo -e "    ${BOLD}q${NC}  Quit"
    echo ""
    echo -ne "  ${CYAN}>${NC} "
    read -r choice

    case "$choice" in
      1)
        echo ""
        echo -ne "  ${BOLD}Describe the task:${NC} "
        read -r TASK
        if [[ -z "$TASK" ]]; then warn "No task entered."; echo ""; continue; fi
        history_add "full" "$TASK"
        return 0  # proceed to full pipeline
        ;;
      2)
        echo ""
        echo -ne "  ${BOLD}Describe the task:${NC} "
        read -r TASK
        if [[ -z "$TASK" ]]; then warn "No task entered."; echo ""; continue; fi
        PLAN_ONLY=true
        history_add "plan-only" "$TASK"
        return 0
        ;;
      3)
        if [[ ! -f "$HARNESS_DIR/plan.md" ]]; then
          warn "No plan found. Run a plan first."
          echo ""
          continue
        fi
        SKIP_PLAN=true
        if [[ -f "$HARNESS_DIR/task.txt" ]]; then
          TASK=$(cat "$HARNESS_DIR/task.txt")
        fi
        history_add "build" "$TASK"
        return 0
        ;;
      4)
        QA_ONLY=true
        if [[ -f "$HARNESS_DIR/task.txt" ]]; then
          TASK=$(cat "$HARNESS_DIR/task.txt")
        fi
        history_add "qa" "$TASK"
        return 0
        ;;
      5)
        echo ""
        echo -e "    ${BOLD}a${NC}  structure.md"
        echo -e "    ${BOLD}b${NC}  plan.md"
        echo -e "    ${BOLD}c${NC}  build-result.md"
        echo -e "    ${BOLD}d${NC}  qa-report.md"
        echo -e "    ${BOLD}e${NC}  run.log"
        echo ""
        echo -ne "  ${CYAN}>${NC} "
        read -r artifact_choice
        local artifact_file=""
        case "$artifact_choice" in
          a) artifact_file="$HARNESS_DIR/structure.md" ;;
          b) artifact_file="$HARNESS_DIR/plan.md" ;;
          c) artifact_file="$HARNESS_DIR/build-result.md" ;;
          d) artifact_file="$HARNESS_DIR/qa-report.md" ;;
          e) artifact_file="$LOG_FILE" ;;
          *) warn "Invalid choice."; echo ""; continue ;;
        esac
        if [[ -f "$artifact_file" ]]; then
          echo ""
          echo -e "  ${DIM}─── $artifact_file ───${NC}"
          echo ""
          # use less if available and output is large, otherwise cat
          if [[ $(wc -l < "$artifact_file") -gt 40 ]] && command -v less &>/dev/null; then
            less -R "$artifact_file"
          else
            cat "$artifact_file"
          fi
          echo ""
          echo -e "  ${DIM}─── end ───${NC}"
        else
          warn "File not found: $artifact_file"
        fi
        echo ""
        ;;
      6)
        history_show
        ;;
      7)
        if [[ -d "$HARNESS_DIR" ]]; then
          rm -rf "$HARNESS_DIR"
          ok "Cleaned $HARNESS_DIR"
          mkdir -p "$HARNESS_DIR"
        else
          info "Nothing to clean."
        fi
        echo ""
        ;;
      q|Q|quit|exit)
        echo ""
        dim "  bye."
        echo ""
        exit 0
        ;;
      *)
        warn "Pick 1-7 or q."
        echo ""
        ;;
    esac
  done
}

# --- Launch interactive mode if no task/flags given --------------------------
if [[ -z "$TASK" && $PLAN_ONLY == false && $SKIP_PLAN == false && $BUILDER_ONLY == false && $QA_ONLY == false ]]; then
  run_interactive
fi

# --- Setup .harness/ ---------------------------------------------------------
mkdir -p "$HARNESS_DIR"
echo "# Harness run: $TIMESTAMP" > "$LOG_FILE"
log "Task: $TASK"
log "Flags: plan_only=$PLAN_ONLY skip_plan=$SKIP_PLAN builder_only=$BUILDER_ONLY qa_only=$QA_ONLY quiet=$QUIET"

# --- Build codebase preamble (auto-detect stack) ----------------------------
build_preamble() {
  local preamble="You are working inside a software project.\n\n"

  # Include CLAUDE.md if present
  if [[ -f "CLAUDE.md" ]]; then
    preamble+="## Project guidance (CLAUDE.md)\n\n"
    preamble+="$(cat CLAUDE.md)\n\n"
  fi

  # Include README for context
  if [[ -f "README.md" ]]; then
    preamble+="## Project README\n\n"
    preamble+="$(head -100 README.md)\n\n"
  elif [[ -f "README" ]]; then
    preamble+="## Project README\n\n"
    preamble+="$(head -100 README)\n\n"
  fi

  # Auto-detect stack from common config files
  local stack_hints=""
  [[ -f "package.json" ]]       && stack_hints+="- Node.js/JavaScript project (package.json present)\n"
  [[ -f "tsconfig.json" ]]      && stack_hints+="- TypeScript configured (tsconfig.json present)\n"
  [[ -f "requirements.txt" ]]   && stack_hints+="- Python project (requirements.txt present)\n"
  [[ -f "pyproject.toml" ]]     && stack_hints+="- Python project (pyproject.toml present)\n"
  [[ -f "Pipfile" ]]            && stack_hints+="- Python project (Pipfile present)\n"
  [[ -f "go.mod" ]]             && stack_hints+="- Go project (go.mod present)\n"
  [[ -f "Cargo.toml" ]]         && stack_hints+="- Rust project (Cargo.toml present)\n"
  [[ -f "Gemfile" ]]            && stack_hints+="- Ruby project (Gemfile present)\n"
  [[ -f "pom.xml" ]]            && stack_hints+="- Java/Maven project (pom.xml present)\n"
  [[ -f "build.gradle" ]]       && stack_hints+="- Java/Gradle project (build.gradle present)\n"
  [[ -f "composer.json" ]]      && stack_hints+="- PHP project (composer.json present)\n"
  [[ -f "Dockerfile" ]]         && stack_hints+="- Docker configured (Dockerfile present)\n"
  [[ -f "docker-compose.yml" || -f "docker-compose.yaml" ]] && stack_hints+="- Docker Compose configured\n"
  [[ -f "Makefile" ]]           && stack_hints+="- Makefile present\n"
  [[ -f ".env.example" ]]       && stack_hints+="- Environment variables used (.env.example present)\n"

  if [[ -n "$stack_hints" ]]; then
    preamble+="## Detected stack\n\n$stack_hints\n"
  fi

  # Include directory overview
  preamble+="## Top-level directory listing\n\n"
  preamble+="$(ls -1 | head -40)\n"

  echo -e "$preamble"
}

CODEBASE_PREAMBLE=$(build_preamble)

# --- Helper: run a claude agent phase ----------------------------------------
run_phase() {
  local name="$1"
  local prompt="$2"
  local output_file="$3"

  phase "$name"
  log "Starting phase: $name"
  info "Running $name agent..."

  local start_time=$SECONDS

  if $QUIET; then
    # Silent mode: output only to file (original behavior)
    if claude -p \
      --dangerously-skip-permissions \
      "$prompt" \
      > "$output_file" 2>>"$LOG_FILE"; then
      local elapsed=$(( SECONDS - start_time ))
      ok "$name completed in ${elapsed}s — output: $output_file"
      log "$name completed in ${elapsed}s"
    else
      local elapsed=$(( SECONDS - start_time ))
      err "$name failed after ${elapsed}s. Check $LOG_FILE for details."
      log "$name FAILED after ${elapsed}s"
      exit 1
    fi
  else
    # Live mode: stream output to terminal AND save to file
    echo ""
    info "─── $name output ───"
    echo ""
    if claude -p \
      --dangerously-skip-permissions \
      "$prompt" \
      2>>"$LOG_FILE" | tee "$output_file"; then
      echo ""
      info "─── end $name output ───"
      local elapsed=$(( SECONDS - start_time ))
      ok "$name completed in ${elapsed}s — output saved: $output_file"
      log "$name completed in ${elapsed}s"
    else
      echo ""
      local elapsed=$(( SECONDS - start_time ))
      err "$name failed after ${elapsed}s. Check $LOG_FILE for details."
      log "$name FAILED after ${elapsed}s"
      exit 1
    fi
  fi
}

# =============================================================================
# Phase 1: STRUCTURER
# Analyzes the codebase and produces a structured map of relevant files/modules.
# =============================================================================
run_structurer() {
  local prompt
  prompt=$(cat <<PROMPT
$CODEBASE_PREAMBLE

## Your role: Structurer

You are the Structurer agent in a multi-agent development pipeline. Your job is to analyze the codebase and produce a structured map that later agents will use.

## Task

The user wants to accomplish the following:

$TASK

## Instructions

1. Explore the repository structure thoroughly — directories, files, configs, tests.
2. Identify which files, modules, and components are relevant to the task.
3. Note any patterns, conventions, or architectural decisions visible in the code.
4. Identify test infrastructure, build tooling, and CI/CD configuration.
5. Flag any potential risks or dependencies that could affect the task.

## Output format

Produce a comprehensive markdown document with these sections:

### Repository overview
Brief summary of what this project is and its architecture.

### Relevant files and modules
A list of files/directories directly relevant to the task, with a 1-line description of each.

### Code patterns and conventions
Naming conventions, file organization patterns, import styles, error handling patterns, etc.

### Test infrastructure
How tests are organized, what frameworks are used, how to run them.

### Dependencies and risks
External dependencies, potential breaking changes, areas of concern.

### Suggested approach
High-level recommendation for how to approach the task given the codebase structure.
PROMPT
  )
  run_phase "Structurer" "$prompt" "$HARNESS_DIR/structure.md"
}

# =============================================================================
# Phase 2: PLANNER
# Reads the structure map and produces a detailed implementation plan.
# =============================================================================
run_planner() {
  local structure
  if [[ -f "$HARNESS_DIR/structure.md" ]]; then
    structure=$(cat "$HARNESS_DIR/structure.md")
  else
    err "No structure file found at $HARNESS_DIR/structure.md — run Structurer first."
    exit 1
  fi

  local prompt
  prompt=$(cat <<PROMPT
$CODEBASE_PREAMBLE

## Your role: Planner

You are the Planner agent in a multi-agent development pipeline. The Structurer has already analyzed the codebase. Your job is to produce a detailed, step-by-step implementation plan.

## Task

The user wants to accomplish the following:

$TASK

## Codebase structure (from Structurer)

$structure

## Instructions

1. Read the structure analysis carefully.
2. Break the task into clear, ordered implementation steps.
3. For each step, specify exactly which files to create/modify and what changes to make.
4. Include test steps — what tests to write and how to verify correctness.
5. Consider edge cases, error handling, and backwards compatibility.
6. Keep steps small and atomic — each step should be independently verifiable.

## Output format

Produce a markdown document with:

### Summary
1-2 sentence summary of the plan.

### Implementation steps

For each step:
#### Step N: <title>
- **Files**: list of files to create or modify
- **Changes**: specific description of what to do
- **Verification**: how to verify this step is correct (test command, manual check, etc.)

### Test plan
What tests to add or modify, and how to run the full test suite.

### Rollback considerations
What to watch out for if something goes wrong.
PROMPT
  )
  run_phase "Planner" "$prompt" "$HARNESS_DIR/plan.md"
}

# =============================================================================
# Phase 3: BUILDER
# Reads the plan and executes it, making actual code changes.
# =============================================================================
run_builder() {
  local plan
  if [[ -f "$HARNESS_DIR/plan.md" ]]; then
    plan=$(cat "$HARNESS_DIR/plan.md")
  else
    err "No plan file found at $HARNESS_DIR/plan.md — run Planner first."
    exit 1
  fi

  local structure=""
  if [[ -f "$HARNESS_DIR/structure.md" ]]; then
    structure=$(cat "$HARNESS_DIR/structure.md")
  fi

  local prompt
  prompt=$(cat <<PROMPT
$CODEBASE_PREAMBLE

## Your role: Builder

You are the Builder agent in a multi-agent development pipeline. The Structurer analyzed the codebase and the Planner produced an implementation plan. Your job is to execute the plan by making actual code changes.

## Task

The user wants to accomplish the following:

$TASK

## Codebase structure (from Structurer)

$structure

## Implementation plan (from Planner)

$plan

## Instructions

1. Follow the implementation plan step by step.
2. Make all necessary code changes — create files, modify existing code, write tests.
3. Follow the existing code conventions and patterns identified by the Structurer.
4. Run tests and fix any failures before finishing.
5. Do NOT skip steps or cut corners. Implement the complete plan.
6. If a step in the plan is unclear or seems wrong, use your judgment to do the right thing, but note the deviation.

## Output format

After completing all changes, produce a summary markdown document with:

### Changes made
List every file created or modified with a brief description of changes.

### Tests
What tests were run and their results.

### Deviations from plan
Any places where you deviated from the plan and why.

### Notes
Anything the QA agent should pay special attention to.
PROMPT
  )
  run_phase "Builder" "$prompt" "$HARNESS_DIR/build-result.md"
}

# =============================================================================
# Phase 4: QA
# Reviews all changes, runs tests, checks for issues.
# =============================================================================
run_qa() {
  local build_result=""
  if [[ -f "$HARNESS_DIR/build-result.md" ]]; then
    build_result=$(cat "$HARNESS_DIR/build-result.md")
  fi

  local plan=""
  if [[ -f "$HARNESS_DIR/plan.md" ]]; then
    plan=$(cat "$HARNESS_DIR/plan.md")
  fi

  local structure=""
  if [[ -f "$HARNESS_DIR/structure.md" ]]; then
    structure=$(cat "$HARNESS_DIR/structure.md")
  fi

  local prompt
  prompt=$(cat <<PROMPT
$CODEBASE_PREAMBLE

## Your role: QA Reviewer

You are the QA agent in a multi-agent development pipeline. The Builder has made code changes. Your job is to thoroughly review everything and ensure quality.

## Task that was implemented

$TASK

## Codebase structure (from Structurer)

$structure

## Implementation plan (from Planner)

$plan

## Build result (from Builder)

$build_result

## Instructions

1. Review ALL changes made by the Builder (use git diff or examine modified files).
2. Check that the implementation matches the plan and task requirements.
3. Run the full test suite and report results.
4. Look for:
   - Bugs, logic errors, off-by-one errors
   - Security vulnerabilities (injection, XSS, auth issues, etc.)
   - Missing error handling or edge cases
   - Code style violations or inconsistencies
   - Missing or inadequate tests
   - Performance concerns
   - Breaking changes to existing functionality
5. Fix any issues you find directly — do not just report them.
6. Run tests again after any fixes.

## Output format

Produce a QA report markdown document with:

### Review summary
Overall assessment: PASS, PASS WITH NOTES, or FAIL.

### Changes reviewed
List of files reviewed.

### Issues found and fixed
For each issue: what it was, severity, and how you fixed it.

### Issues found but not fixed
Any issues that need human judgment or are out of scope.

### Test results
Full test output or summary.

### Final assessment
Is this ready to merge? Any caveats?
PROMPT
  )
  run_phase "QA" "$prompt" "$HARNESS_DIR/qa-report.md"
}

# =============================================================================
# Main execution
# =============================================================================

# Save task for resume flows
if [[ -n "$TASK" ]]; then
  echo "$TASK" > "$HARNESS_DIR/task.txt"
elif [[ -f "$HARNESS_DIR/task.txt" ]]; then
  TASK=$(cat "$HARNESS_DIR/task.txt")
fi

# Log to history if invoked from CLI (interactive mode logs its own)
if [[ -n "$TASK" && ! -f "$HARNESS_DIR/.interactive" ]]; then
  local_mode="full"
  $PLAN_ONLY && local_mode="plan-only"
  $SKIP_PLAN && local_mode="build"
  $BUILDER_ONLY && local_mode="builder-only"
  $QA_ONLY && local_mode="qa"
  history_add "$local_mode" "$TASK"
fi

if $QA_ONLY; then
  run_qa
elif $BUILDER_ONLY; then
  run_builder
elif $SKIP_PLAN; then
  run_builder
  run_qa
elif $PLAN_ONLY; then
  run_structurer
  run_planner
  ok "Plan complete. Review $HARNESS_DIR/plan.md then run: ./harness.sh --skip-plan"
else
  run_structurer
  run_planner
  run_builder
  run_qa
fi

phase "Done"
ok "Harness run complete. Artifacts in $HARNESS_DIR/"
info "  Structure:    $HARNESS_DIR/structure.md"
info "  Plan:         $HARNESS_DIR/plan.md"
info "  Build result: $HARNESS_DIR/build-result.md"
info "  QA report:    $HARNESS_DIR/qa-report.md"
info "  Log:          $LOG_FILE"
