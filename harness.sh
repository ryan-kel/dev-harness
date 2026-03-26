#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-harness: Multi-agent development harness using Claude Code CLI
# Chains 4 agents: Structurer -> Planner -> Builder -> QA
# Communication via markdown artifacts in .harness/
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HARNESS_DIR=".harness"
SESSIONS_DIR="$HARNESS_DIR/sessions"
HISTORY_FILE="$HARNESS_DIR/history.log"
LOG_FILE="$HARNESS_DIR/run.log"
SESSION_FILE=""
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
TOTAL_COST=0

# --- Colors & output helpers -------------------------------------------------
RED='\033[0;31m'
BRIGHT_RED='\033[1;31m'
GREEN='\033[0;32m'
BRIGHT_GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BRIGHT_CYAN='\033[1;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "  ${BLUE}ℹ${NC}  $*"; }
ok()    { echo -e "  ${BRIGHT_GREEN}✓${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}!${NC}  $*"; }
err()   { echo -e "  ${BRIGHT_RED}✗${NC}  $*" >&2; }
phase() { echo -e "\n  ${WHITE}════${NC} ${BOLD}${BRIGHT_CYAN}$*${NC} ${WHITE}════${NC}\n"; }
dim()   { echo -e "  ${DIM}$*${NC}"; }
ts()    { echo -e "  ${DIM}$(date +"%H:%M:%S")${NC}  $*"; }

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
  --fresh           Force re-run structurer even if recent structure exists
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
FRESH=false
TASK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-only)     PLAN_ONLY=true; shift ;;
    --skip-plan)     SKIP_PLAN=true; shift ;;
    --builder-only)  BUILDER_ONLY=true; shift ;;
    --qa-only)       QA_ONLY=true; shift ;;
    --quiet)         QUIET=true; shift ;;
    --fresh)         FRESH=true; shift ;;
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

# --- Validate dependencies ---------------------------------------------------
if ! command -v claude &>/dev/null; then
  err "Claude Code CLI not found. Install it first: https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  err "python3 is required for live streaming. Install it first."
  exit 1
fi

# --- History helpers ---------------------------------------------------------
history_add() {
  mkdir -p "$HARNESS_DIR"
  echo "$(date +"%Y-%m-%d %H:%M") | $1 | $2" >> "$HISTORY_FILE"
}

# --- Session stats -----------------------------------------------------------
get_session_stats() {
  # Returns "count total_cost" from session files
  python3 -c "
import json, glob, os
sessions_dir = '$SESSIONS_DIR'
total_cost = 0.0
count = 0
for f in sorted(glob.glob(os.path.join(sessions_dir, '*.json'))):
    try:
        with open(f) as fh:
            s = json.load(fh)
        total_cost += s.get('total_cost_usd', 0)
        count += 1
    except: pass
print(f'{count} {total_cost:.2f}')
" 2>/dev/null || echo "0 0.00"
}

sessions_show() {
  if [[ ! -d "$SESSIONS_DIR" ]] || [[ -z "$(ls -A "$SESSIONS_DIR" 2>/dev/null)" ]]; then
    dim "  No sessions yet."
    echo ""
    return
  fi

  echo ""
  echo -e "  ${BOLD}Recent sessions${NC}"
  echo -e "  ${DIM}────────────────────────────────────────────────────────────────${NC}"

  python3 -c "
import json, glob, os
sessions_dir = '$SESSIONS_DIR'
files = sorted(glob.glob(os.path.join(sessions_dir, '*.json')))[-10:]
for i, f in enumerate(files, 1):
    try:
        with open(f) as fh:
            s = json.load(fh)
        task = s.get('task', '?')[:35]
        mode = s.get('mode', '?')
        dur = s.get('total_duration_s', 0)
        cost = s.get('total_cost_usd', 0)
        verdict = s.get('qa_verdict', '--')
        started = s.get('started', '?')

        # Format duration
        if dur >= 60:
            dur_str = f'{dur // 60}m{dur % 60:02.0f}s'
        else:
            dur_str = f'{dur:.0f}s'

        # Format date (from YYYY-MM-DD_HH-MM-SS)
        parts = started.split('_')
        date_part = parts[0][5:] if len(parts) > 0 else '?'  # MM-DD
        time_part = parts[1][:5].replace('-', ':') if len(parts) > 1 else '?'

        # Color verdict
        v_color = ''
        if verdict == 'PASS':
            v_color = '\033[1;32m'
        elif verdict == 'FAIL':
            v_color = '\033[1;31m'
        else:
            v_color = '\033[2m'

        print(f'  \033[2m{i:>2}\033[0m  {date_part} {time_part}  \033[1m{mode:<11}\033[0m {dur_str:>6}  \033[2m\${cost:.2f}\033[0m  {v_color}{verdict:<4}\033[0m  \033[2m{task}\033[0m')
    except: pass
" 2>/dev/null

  echo ""
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
    echo -e "    ${BRIGHT_GREEN}●${NC} ${BOLD}$label${NC} ${DIM}(${size}B, $modified)${NC}"
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
  local stats
  stats=$(get_session_stats)
  local count=${stats%% *}
  local total_cost=${stats##* }

  echo ""
  echo -e "  ${WHITE}┌─────────────────────────────────────────────────┐${NC}"
  echo -e "  ${WHITE}│${NC}                                                 ${WHITE}│${NC}"
  echo -e "  ${WHITE}│${NC}   ${BOLD}${BRIGHT_CYAN}dev-harness${NC}  ${DIM}multi-agent pipeline${NC}          ${WHITE}│${NC}"
  if [[ "$count" -gt 0 ]]; then
    echo -e "  ${WHITE}│${NC}   ${DIM}${count} sessions${NC} ${DIM}|${NC} ${DIM}\$${total_cost} total${NC}                   ${WHITE}│${NC}"
  fi
  echo -e "  ${WHITE}│${NC}                                                 ${WHITE}│${NC}"
  echo -e "  ${WHITE}└─────────────────────────────────────────────────┘${NC}"
  echo -e "  ${DIM}$(basename "$(pwd)")${NC}"
}

# --- Interactive mode --------------------------------------------------------
run_interactive() {
  show_banner
  show_status

  # Check what's available for smart menu
  local has_plan=false
  local has_build=false
  [[ -f "$HARNESS_DIR/plan.md" ]] && has_plan=true
  [[ -f "$HARNESS_DIR/build-result.md" ]] && has_build=true

  while true; do
    echo -e "  ${BOLD}What do you want to do?${NC}"
    echo ""
    # Check structure freshness for hints
    local struct_hint=""
    if [[ -f "$HARNESS_DIR/structure.md" ]]; then
      local struct_age=$(( ( $(date +%s) - $(stat -c %Y "$HARNESS_DIR/structure.md") ) / 60 ))
      if [[ "$struct_age" -lt 60 ]]; then
        struct_hint=" ${DIM}(reusing structure)${NC}"
      fi
    fi

    echo -e "    ${BRIGHT_CYAN}1${NC}  ${BOLD}New task${NC}            ${DIM}full pipeline${NC}${struct_hint}"
    echo -e "    ${BRIGHT_CYAN}2${NC}  ${BOLD}Plan only${NC}           ${DIM}structure + plan, no code changes${NC}"

    if $has_plan; then
      echo -e "    ${BRIGHT_CYAN}3${NC}  ${BOLD}Build from plan${NC}     ${DIM}execute existing plan${NC}"
    else
      echo -e "    ${DIM}    3  Build from plan     (no plan yet)${NC}"
    fi

    if $has_build; then
      echo -e "    ${BRIGHT_CYAN}4${NC}  ${BOLD}QA only${NC}             ${DIM}review current changes${NC}"
    else
      echo -e "    ${DIM}    4  QA only             (no build yet)${NC}"
    fi

    echo -e "    ${BRIGHT_CYAN}5${NC}  ${BOLD}View artifact${NC}       ${DIM}read an output file${NC}"
    echo -e "    ${BRIGHT_CYAN}6${NC}  ${BOLD}Sessions${NC}            ${DIM}past runs with cost & status${NC}"
    echo -e "    ${BRIGHT_CYAN}7${NC}  ${BOLD}Clean${NC}               ${DIM}wipe .harness/${NC}"
    echo -e "    ${DIM}q  Quit${NC}"
    echo ""
    echo -ne "  ${BRIGHT_CYAN}>${NC} "
    read -r choice

    case "$choice" in
      1)
        echo ""
        echo -ne "  ${BOLD}Describe the task:${NC}\n\n  ${BRIGHT_CYAN}>${NC} "
        read -r TASK
        if [[ -z "$TASK" ]]; then warn "No task entered."; echo ""; continue; fi
        echo ""
        ok "Task received"
        echo ""
        echo -e "  ${WHITE}\"${NC}${BOLD}$TASK${NC}${WHITE}\"${NC}"
        echo ""
        ts "Mode: ${BOLD}full pipeline${NC} (4 phases)"
        echo ""
        history_add "full" "$TASK"
        return 0
        ;;
      2)
        echo ""
        echo -ne "  ${BOLD}Describe the task:${NC}\n\n  ${BRIGHT_CYAN}>${NC} "
        read -r TASK
        if [[ -z "$TASK" ]]; then warn "No task entered."; echo ""; continue; fi
        echo ""
        ok "Task received"
        echo ""
        echo -e "  ${WHITE}\"${NC}${BOLD}$TASK${NC}${WHITE}\"${NC}"
        echo ""
        ts "Mode: ${BOLD}plan only${NC} (2 phases, no code changes)"
        echo ""
        PLAN_ONLY=true
        history_add "plan-only" "$TASK"
        return 0
        ;;
      3)
        if ! $has_plan; then
          warn "No plan found. Run option 2 first."
          echo ""
          continue
        fi
        SKIP_PLAN=true
        if [[ -f "$HARNESS_DIR/task.txt" ]]; then
          TASK=$(cat "$HARNESS_DIR/task.txt")
        fi
        echo ""
        ts "Resuming from existing plan — launching Builder..."
        echo ""
        history_add "build" "$TASK"
        return 0
        ;;
      4)
        if ! $has_build; then
          warn "No build found. Run a build first."
          echo ""
          continue
        fi
        QA_ONLY=true
        if [[ -f "$HARNESS_DIR/task.txt" ]]; then
          TASK=$(cat "$HARNESS_DIR/task.txt")
        fi
        echo ""
        ts "Launching QA review..."
        echo ""
        history_add "qa" "$TASK"
        return 0
        ;;
      5)
        echo ""
        for pair in "a:structure.md" "b:plan.md" "c:build-result.md" "d:qa-report.md" "e:run.log"; do
          local key="${pair%%:*}"
          local fname="${pair##*:}"
          local fpath="$HARNESS_DIR/$fname"
          [[ "$fname" == "run.log" ]] && fpath="$LOG_FILE"
          if [[ -f "$fpath" ]]; then
            echo -e "    ${BRIGHT_CYAN}${key}${NC}  ${BOLD}$fname${NC}"
          else
            echo -e "    ${DIM}${key}  $fname  (empty)${NC}"
          fi
        done
        echo ""
        echo -ne "  ${BRIGHT_CYAN}>${NC} "
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
          echo -e "  ${WHITE}─── ${BOLD}$artifact_file${NC} ${WHITE}───${NC}"
          echo ""
          if [[ $(wc -l < "$artifact_file") -gt 40 ]] && command -v less &>/dev/null; then
            less -R "$artifact_file"
          else
            cat "$artifact_file"
          fi
          echo ""
          echo -e "  ${WHITE}─── end ───${NC}"
        else
          warn "File not found: $artifact_file"
        fi
        echo ""
        ;;
      6)
        sessions_show
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
        dim "bye."
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
INTERACTIVE=false
if [[ -z "$TASK" && $PLAN_ONLY == false && $SKIP_PLAN == false && $BUILDER_ONLY == false && $QA_ONLY == false ]]; then
  INTERACTIVE=true
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
  local phase_idx="${4:-0}"
  local total_phases="${5:-0}"

  local phase_label="$name"
  if [[ "$total_phases" -gt 0 ]]; then
    phase_label="$name ${DIM}[$phase_idx/$total_phases]${NC}"
  fi

  phase "$phase_label"
  log "Starting phase: $name [$phase_idx/$total_phases]"
  ts "Connecting to Claude..."

  local start_time=$SECONDS

  if $QUIET; then
    # Silent mode: output only to file (original behavior)
    if claude -p \
      --dangerously-skip-permissions \
      "$prompt" \
      > "$output_file" 2>>"$LOG_FILE"; then
      local elapsed=$(( SECONDS - start_time ))
      ts "${BRIGHT_GREEN}✓${NC} $name completed in ${elapsed}s — output: $output_file"
      log "$name completed in ${elapsed}s"
    else
      local elapsed=$(( SECONDS - start_time ))
      err "$name failed after ${elapsed}s. Check $LOG_FILE for details."
      log "$name FAILED after ${elapsed}s"
      exit 1
    fi
  else
    # Live mode: stream tool calls and text via stream processor
    echo ""
    if claude -p --verbose \
      --output-format stream-json \
      --dangerously-skip-permissions \
      "$prompt" \
      2>>"$LOG_FILE" | python3 "$SCRIPT_DIR/stream_processor.py" \
        "$output_file" "$name" "$SESSION_FILE"; then
      local elapsed=$(( SECONDS - start_time ))
      echo ""
      ts "${BRIGHT_GREEN}✓${NC} $name completed in ${elapsed}s — saved: ${DIM}$output_file${NC}"
      log "$name completed in ${elapsed}s"
    else
      local elapsed=$(( SECONDS - start_time ))
      echo ""
      ts "${BRIGHT_RED}✗${NC} $name failed after ${elapsed}s. Check $LOG_FILE for details."
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
  run_phase "Structurer" "$prompt" "$HARNESS_DIR/structure.md" "$CURRENT_PHASE" "$TOTAL_PHASES"
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
  run_phase "Planner" "$prompt" "$HARNESS_DIR/plan.md" "$CURRENT_PHASE" "$TOTAL_PHASES"
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
  run_phase "Builder" "$prompt" "$HARNESS_DIR/build-result.md" "$CURRENT_PHASE" "$TOTAL_PHASES"
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
  run_phase "QA" "$prompt" "$HARNESS_DIR/qa-report.md" "$CURRENT_PHASE" "$TOTAL_PHASES"
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

# Determine run mode
RUN_MODE="full"
$PLAN_ONLY && RUN_MODE="plan-only"
$SKIP_PLAN && RUN_MODE="build"
$BUILDER_ONLY && RUN_MODE="builder-only"
$QA_ONLY && RUN_MODE="qa"

# Log to history if invoked from CLI (interactive mode logs its own)
if [[ -n "$TASK" && ! -f "$HARNESS_DIR/.interactive" ]]; then
  history_add "$RUN_MODE" "$TASK"
fi

# --- Compute total phases and set up session ----------------------------------
TOTAL_PHASES=4
CURRENT_PHASE=0
if $QA_ONLY; then TOTAL_PHASES=1
elif $BUILDER_ONLY; then TOTAL_PHASES=1
elif $SKIP_PLAN; then TOTAL_PHASES=2
elif $PLAN_ONLY; then TOTAL_PHASES=2
fi

# Create session file
mkdir -p "$SESSIONS_DIR"
SESSION_FILE="$SESSIONS_DIR/${TIMESTAMP}.json"
python3 -c "
import json, os, sys
session = {
    'task': sys.argv[1],
    'mode': sys.argv[2],
    'started': sys.argv[3],
    'cwd': os.getcwd(),
    'phases': []
}
with open(sys.argv[4], 'w') as f:
    json.dump(session, f, indent=2)
" "$TASK" "$RUN_MODE" "$TIMESTAMP" "$SESSION_FILE"

RUN_START=$SECONDS

# --- Check if structurer can be skipped ---------------------------------------
SKIP_STRUCTURER=false
STRUCTURE_AGE_MIN=""

if [[ -f "$HARNESS_DIR/structure.md" ]] && ! $FRESH; then
  # Get age in minutes
  STRUCTURE_AGE_MIN=$(( ( $(date +%s) - $(stat -c %Y "$HARNESS_DIR/structure.md") ) / 60 ))
  if [[ "$STRUCTURE_AGE_MIN" -lt 60 ]]; then
    SKIP_STRUCTURER=true
  fi
fi

# Adjust phase counts if skipping structurer
if $SKIP_STRUCTURER; then
  if $PLAN_ONLY; then
    TOTAL_PHASES=1  # just planner
  elif ! $QA_ONLY && ! $BUILDER_ONLY && ! $SKIP_PLAN; then
    TOTAL_PHASES=3  # planner + builder + qa
  fi
fi

# --- Execute pipeline ---------------------------------------------------------
if $QA_ONLY; then
  CURRENT_PHASE=1; run_qa
elif $BUILDER_ONLY; then
  CURRENT_PHASE=1; run_builder
elif $SKIP_PLAN; then
  CURRENT_PHASE=1; run_builder
  CURRENT_PHASE=2; run_qa
elif $PLAN_ONLY; then
  if $SKIP_STRUCTURER; then
    ts "Reusing existing structure.md ${DIM}(${STRUCTURE_AGE_MIN} min old)${NC}"
    echo ""
    CURRENT_PHASE=1; run_planner
  else
    CURRENT_PHASE=1; run_structurer
    CURRENT_PHASE=2; run_planner
  fi
else
  if $SKIP_STRUCTURER; then
    ts "Reusing existing structure.md ${DIM}(${STRUCTURE_AGE_MIN} min old)${NC}"
    echo ""
    CURRENT_PHASE=1; run_planner
    CURRENT_PHASE=2; run_builder
    CURRENT_PHASE=3; run_qa
  else
    CURRENT_PHASE=1; run_structurer
    CURRENT_PHASE=2; run_planner
    CURRENT_PHASE=3; run_builder
    CURRENT_PHASE=4; run_qa
  fi
fi

# --- Finalize session ---------------------------------------------------------
TOTAL_ELAPSED=$(( SECONDS - RUN_START ))

# Extract QA verdict if qa-report exists
QA_VERDICT="--"
if [[ -f "$HARNESS_DIR/qa-report.md" ]]; then
  QA_VERDICT=$(grep -oEi '(PASS|FAIL)' "$HARNESS_DIR/qa-report.md" | head -1 || echo "--")
  [[ -z "$QA_VERDICT" ]] && QA_VERDICT="--"
fi

# Update session file with totals
python3 -c "
import json, sys
try:
    sf, elapsed, verdict = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    with open(sf, 'r') as f:
        session = json.load(f)
    session['total_duration_s'] = elapsed
    total_cost = sum(p.get('cost_usd', 0) for p in session.get('phases', []))
    session['total_cost_usd'] = round(total_cost, 6)
    session['qa_verdict'] = verdict
    with open(sf, 'w') as f:
        json.dump(session, f, indent=2)
except Exception:
    pass
" "$SESSION_FILE" "$TOTAL_ELAPSED" "$QA_VERDICT"

# --- Summary card -------------------------------------------------------------
# Format duration nicely
if [[ $TOTAL_ELAPSED -ge 60 ]]; then
  DURATION_FMT="$(( TOTAL_ELAPSED / 60 ))m$(( TOTAL_ELAPSED % 60 ))s"
else
  DURATION_FMT="${TOTAL_ELAPSED}s"
fi

# Read total cost from session
TOTAL_COST=$(python3 -c "
import json
try:
    with open('$SESSION_FILE') as f:
        s = json.load(f)
    print(f\"\${s.get('total_cost_usd', 0):.4f}\")
except: print('\$0.0000')
" 2>/dev/null)

# Colorize QA verdict
QA_COLOR="$DIM"
if [[ "$QA_VERDICT" == "PASS" ]]; then QA_COLOR="$BRIGHT_GREEN"
elif [[ "$QA_VERDICT" == "FAIL" ]]; then QA_COLOR="$BRIGHT_RED"
fi

echo ""
echo -e "  ${WHITE}┌─ Run complete ────────────────────────────────┐${NC}"
echo -e "  ${WHITE}│${NC}                                                ${WHITE}│${NC}"
echo -e "  ${WHITE}│${NC}  ${BOLD}Task:${NC}    $(printf '%-39s' "$TASK" | head -c 39)  ${WHITE}│${NC}"
echo -e "  ${WHITE}│${NC}  ${BOLD}Phases:${NC}  $TOTAL_PHASES/$TOTAL_PHASES      ${BOLD}Time:${NC} $(printf '%-13s' "$DURATION_FMT")  ${WHITE}│${NC}"
echo -e "  ${WHITE}│${NC}  ${BOLD}Cost:${NC}    $(printf '%-12s' "$TOTAL_COST")${BOLD}QA:${NC}   ${QA_COLOR}$(printf '%-13s' "$QA_VERDICT")${NC}  ${WHITE}│${NC}"
echo -e "  ${WHITE}│${NC}                                                ${WHITE}│${NC}"

# Artifact dots
ARTIFACTS_LINE=""
for artifact in structure.md plan.md build-result.md qa-report.md; do
  if [[ -f "$HARNESS_DIR/$artifact" ]]; then
    ARTIFACTS_LINE+="  ${GREEN}●${NC} $artifact"
  else
    ARTIFACTS_LINE+="  ${DIM}○ $artifact${NC}"
  fi
done
echo -e "  ${WHITE}│${NC} ${ARTIFACTS_LINE}  ${WHITE}│${NC}"
echo -e "  ${WHITE}│${NC}                                                ${WHITE}│${NC}"
echo -e "  ${WHITE}└────────────────────────────────────────────────┘${NC}"

# --- Suggested next steps -----------------------------------------------------
show_next_steps() {
  local steps=()

  if $PLAN_ONLY; then
    steps+=("Review plan:     ${CYAN}cat $HARNESS_DIR/plan.md${NC}")
    steps+=("Execute plan:    ${CYAN}harness --skip-plan${NC}")
  elif [[ "$QA_VERDICT" == "PASS" ]]; then
    steps+=("Review changes:  ${CYAN}git diff${NC}")
    steps+=("Commit:          ${CYAN}git add -p && git commit${NC}")
  elif [[ "$QA_VERDICT" == "FAIL" ]]; then
    steps+=("Check report:    ${CYAN}cat $HARNESS_DIR/qa-report.md${NC}")
    steps+=("Re-run QA:       ${CYAN}harness --qa-only${NC}")
    steps+=("Retry build:     ${CYAN}harness --builder-only${NC}")
  elif $BUILDER_ONLY; then
    steps+=("Run QA:          ${CYAN}harness --qa-only${NC}")
  elif $QA_ONLY; then
    if [[ "$QA_VERDICT" == "PASS" ]]; then
      steps+=("Review changes:  ${CYAN}git diff${NC}")
      steps+=("Commit:          ${CYAN}git add -p && git commit${NC}")
    else
      steps+=("Fix and retry:   ${CYAN}harness --builder-only${NC}")
    fi
  else
    steps+=("Review changes:  ${CYAN}git diff${NC}")
    steps+=("View artifacts:  ${CYAN}harness${NC}  ${DIM}(interactive menu)${NC}")
  fi

  echo ""
  echo -e "  ${WHITE}┌─ Next steps ───────────────────────────────────┐${NC}"
  for step in "${steps[@]}"; do
    echo -e "  ${WHITE}│${NC}  $step"
  done
  echo -e "  ${WHITE}└────────────────────────────────────────────────┘${NC}"
  echo ""
}

show_next_steps

# --- Return to interactive menu if we came from there -------------------------
if $INTERACTIVE; then
  echo -e "  ${DIM}Press enter to return to menu, or q to quit${NC}"
  echo -ne "  ${BRIGHT_CYAN}>${NC} "
  read -r post_choice
  if [[ "$post_choice" == "q" || "$post_choice" == "Q" || "$post_choice" == "quit" ]]; then
    echo ""
    dim "bye."
    echo ""
    exit 0
  fi

  # Re-exec with clean state to return to interactive menu
  exec "$SCRIPT_DIR/harness.sh"
fi
