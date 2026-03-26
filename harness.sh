#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev-harness v1.0.0: Multi-agent development harness using Claude Code CLI
# Chains 4 agents: Structurer -> Planner -> Builder -> QA
# Communication via markdown artifacts in .harness/
# =============================================================================

HARNESS_VERSION="1.0.0"

# --- Portable helpers --------------------------------------------------------
# macOS-compatible readlink -f
portable_readlink() {
  local target="$1"
  cd "$(dirname "$target")"
  target=$(basename "$target")
  while [[ -L "$target" ]]; do
    target=$(readlink "$target")
    cd "$(dirname "$target")"
    target=$(basename "$target")
  done
  echo "$(pwd -P)/$target"
}

# macOS-compatible file modification time (epoch seconds)
portable_mtime() {
  if stat -c %Y "$1" &>/dev/null; then
    stat -c %Y "$1"
  elif stat -f %m "$1" &>/dev/null; then
    stat -f %m "$1"
  else
    echo 0
  fi
}

# macOS-compatible file date display
portable_file_date() {
  local file="$1" fmt="${2:-%H:%M}"
  if date -r "$file" +"$fmt" 2>/dev/null; then
    return
  fi
  local mtime
  mtime=$(portable_mtime "$file")
  date -d "@$mtime" +"$fmt" 2>/dev/null || echo "?"
}

SCRIPT_DIR="$(cd "$(dirname "$(portable_readlink "${BASH_SOURCE[0]}")")" && pwd)"
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

# Terminal width (fallback 80)
term_width() { local w; w=$(tput cols 2>/dev/null) && [[ "$w" -gt 0 ]] && echo "$w" || echo 80; }

# Horizontal rule: hr [char] [width]  — defaults to ─ and full terminal width minus 4 (2-char indent each side)
hr() {
  local ch="${1:-─}" w="${2:-0}"
  [[ "$w" -le 0 ]] && w=$(( $(term_width) - 4 ))
  local i
  for (( i=0; i<w; i++ )); do printf '%s' "$ch"; done
}

# Wrap text to fit inside a 2-char indent on each side
wrap_text() {
  local text="$1" max_w="${2:-0}"
  [[ "$max_w" -le 0 ]] && max_w=$(( $(term_width) - 4 ))
  echo "$text" | fold -s -w "$max_w"
}

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

# --- Config ------------------------------------------------------------------
# Defaults (overridden by .harness/config.sh, then CLI flags)
HARNESS_MODEL=""
HARNESS_MODEL_STRUCTURER=""
HARNESS_MODEL_PLANNER=""
HARNESS_MODEL_BUILDER=""
HARNESS_MODEL_QA=""
HARNESS_MAX_TURNS=0
HARNESS_STRUCTURE_TTL=240
HARNESS_QUIET=false

CONFIG_FILE="$HARNESS_DIR/config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

init_config() {
  mkdir -p "$HARNESS_DIR"
  if [[ -f "$CONFIG_FILE" ]]; then
    warn "Config already exists: $CONFIG_FILE"
    exit 0
  fi
  cat > "$CONFIG_FILE" << 'CONF'
# dev-harness configuration
# CLI flags override these settings.

# Default model for all phases (e.g., "opus", "sonnet", "haiku")
# HARNESS_MODEL=""

# Per-phase model overrides (empty = use HARNESS_MODEL)
# HARNESS_MODEL_STRUCTURER=""
# HARNESS_MODEL_PLANNER=""
# HARNESS_MODEL_BUILDER=""
# HARNESS_MODEL_QA=""

# Max tool-use turns per phase (0 = unlimited)
# HARNESS_MAX_TURNS=0

# Structure cache TTL in minutes (default: 240 = 4 hours)
# HARNESS_STRUCTURE_TTL=240

# Suppress live output (true/false)
# HARNESS_QUIET=false
CONF
  ok "Created $CONFIG_FILE — edit to customize."
  exit 0
}

# --- Usage -------------------------------------------------------------------
usage() {
  echo -e "${BOLD}dev-harness${NC} v${HARNESS_VERSION}  ${DIM}multi-agent development pipeline${NC}"
  echo ""
  echo -e "${BOLD}Usage:${NC} harness [OPTIONS] <task-description>"
  echo ""
  echo -e "${BOLD}Modes:${NC}"
  echo -e "  ${BRIGHT_CYAN}(default)${NC}          Full pipeline: structure > plan > build > QA"
  echo -e "  ${BRIGHT_CYAN}--plan-only${NC}        Structure + plan only (no code changes)"
  echo -e "  ${BRIGHT_CYAN}--skip-plan${NC}        Build + QA from existing plan"
  echo -e "  ${BRIGHT_CYAN}--builder-only${NC}     Build phase only"
  echo -e "  ${BRIGHT_CYAN}--qa-only${NC}          QA phase only"
  echo -e "  ${BRIGHT_CYAN}--resume${NC}           Resume from last interrupted phase"
  echo -e "  ${BRIGHT_CYAN}--dry-run${NC}          Show what would run, without executing"
  echo ""
  echo -e "${BOLD}Options:${NC}"
  echo -e "  ${BRIGHT_CYAN}--model${NC} <name>     Model for all phases (opus, sonnet, haiku)"
  echo -e "  ${BRIGHT_CYAN}--max-turns${NC} <n>    Max tool turns per phase"
  echo -e "  ${BRIGHT_CYAN}--quiet${NC}            Suppress live agent output"
  echo -e "  ${BRIGHT_CYAN}--fresh${NC}            Force re-run structurer"
  echo -e "  ${BRIGHT_CYAN}--no-structure${NC}     Skip structurer entirely (use existing or none)"
  echo -e "  ${BRIGHT_CYAN}--init-config${NC}      Create .harness/config.sh template"
  echo -e "  ${BRIGHT_CYAN}--clean${NC}            Remove .harness/ and exit"
  echo -e "  ${BRIGHT_CYAN}--version${NC}          Show version"
  echo -e "  ${BRIGHT_CYAN}-h, --help${NC}         Show this help"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo -e "  harness \"Add JWT authentication\""
  echo -e "  harness --plan-only \"Refactor database layer\""
  echo -e "  harness --skip-plan"
  echo -e "  harness --model sonnet --plan-only \"Explore auth options\""
  echo -e "  harness --dry-run \"Add caching layer\""
  exit 0
}

# --- Arg parsing -------------------------------------------------------------
PLAN_ONLY=false
SKIP_PLAN=false
BUILDER_ONLY=false
QA_ONLY=false
CLEAN=false
QUIET=$HARNESS_QUIET
FRESH=false
NO_STRUCTURE=false
DRY_RUN=false
RESUME=false
TASK=""
CLI_MODEL=""
CLI_MAX_TURNS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-only)     PLAN_ONLY=true; shift ;;
    --skip-plan)     SKIP_PLAN=true; shift ;;
    --builder-only)  BUILDER_ONLY=true; shift ;;
    --qa-only)       QA_ONLY=true; shift ;;
    --quiet)         QUIET=true; shift ;;
    --fresh)         FRESH=true; shift ;;
    --no-structure)  NO_STRUCTURE=true; shift ;;
    --clean)         CLEAN=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --resume)        RESUME=true; shift ;;
    --init-config)   init_config ;;
    --version)       echo "dev-harness v${HARNESS_VERSION}"; exit 0 ;;
    --model)
      if [[ $# -lt 2 ]]; then err "--model requires a value"; exit 1; fi
      CLI_MODEL="$2"; shift 2 ;;
    --max-turns)
      if [[ $# -lt 2 ]]; then err "--max-turns requires a value"; exit 1; fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then err "--max-turns must be a number"; exit 1; fi
      CLI_MAX_TURNS="$2"; shift 2 ;;
    -h|--help)       usage ;;
    -*)              err "Unknown option: $1"; echo ""; usage ;;
    *)               TASK="$1"; shift ;;
  esac
done

# Apply CLI overrides
[[ -n "$CLI_MODEL" ]] && HARNESS_MODEL="$CLI_MODEL"
[[ -n "$CLI_MAX_TURNS" ]] && HARNESS_MAX_TURNS="$CLI_MAX_TURNS"

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
  err "Claude Code CLI not found. Install: https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  err "python3 is required for live streaming."
  exit 1
fi

# --- History helpers ---------------------------------------------------------
history_add() {
  mkdir -p "$HARNESS_DIR"
  echo "$(date +"%Y-%m-%d %H:%M") | $1 | $2" >> "$HISTORY_FILE"
}

# --- Session stats -----------------------------------------------------------
get_session_stats() {
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

# Cost estimate from historical averages
estimate_cost() {
  local mode="$1"
  python3 -c "
import json, glob, os
sessions_dir = '$SESSIONS_DIR'
costs = []
for f in sorted(glob.glob(os.path.join(sessions_dir, '*.json')))[-20:]:
    try:
        with open(f) as fh:
            s = json.load(fh)
        if s.get('mode') == '$mode' and s.get('total_cost_usd', 0) > 0:
            costs.append(s['total_cost_usd'])
    except: pass
if costs:
    avg = sum(costs) / len(costs)
    print(f'~\${avg:.2f} (avg of {len(costs)} runs)')
else:
    print('')
" 2>/dev/null || echo ""
}

sessions_show() {
  if [[ ! -d "$SESSIONS_DIR" ]] || [[ -z "$(ls -A "$SESSIONS_DIR" 2>/dev/null)" ]]; then
    dim "  No sessions yet."
    echo ""
    return
  fi

  echo ""
  echo -e "  ${BOLD}Recent sessions${NC}"

  python3 -c "
import json, glob, os, shutil
tw = shutil.get_terminal_size((80, 24)).columns
# Fixed columns: #(3) + Date(12) + Mode(12) + Time(7) + Tokens(9) + Cost(8) + QA(5) + spacing(~10) = ~66
fixed_cols = 66
task_w = max(tw - fixed_cols, 10)
sessions_dir = '$SESSIONS_DIR'

hdr = '  \033[2m#   Date       Mode        Time   Tokens    Cost  QA   %-*s\033[0m' % (task_w, 'Task')
sep = '  \033[2m─── ────────── ─────────── ────── ──────── ───── ──── %s\033[0m' % ('─' * task_w)
print(hdr)
print(sep)

files = sorted(glob.glob(os.path.join(sessions_dir, '*.json')))[-10:]
for i, f in enumerate(files, 1):
    try:
        with open(f) as fh:
            s = json.load(fh)
        task = s.get('task', '?')[:task_w]
        mode = s.get('mode', '?')
        dur = s.get('total_duration_s', 0)
        cost = s.get('total_cost_usd', 0)
        verdict = s.get('qa_verdict', '--')
        started = s.get('started', '?')

        tokens = sum(p.get('total_tokens', 0) for p in s.get('phases', []))
        tok_str = f'{tokens / 1000:.1f}K' if tokens >= 1000 else str(tokens)
        dur_str = f'{dur // 60}m{dur % 60:02.0f}s' if dur >= 60 else f'{dur:.0f}s'

        parts = started.split('_')
        date_part = parts[0][5:] if len(parts) > 0 else '?'
        time_part = parts[1][:5].replace('-', ':') if len(parts) > 1 else '?'

        v_color = ''
        if verdict in ('PASS', 'PASS WITH NOTES'):
            v_color = '\033[1;32m'
        elif verdict == 'FAIL':
            v_color = '\033[1;31m'
        else:
            v_color = '\033[2m'

        print(f'  \033[2m{i:>2}\033[0m  {date_part} {time_part}  \033[1m{mode:<11}\033[0m {dur_str:>6}  {tok_str:>6}tok  \033[2m\${cost:.2f}\033[0m  {v_color}{verdict:<4}\033[0m  \033[2m{task}\033[0m')
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
    modified=$(portable_file_date "$file" "%H:%M")
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
  local w=$(( $(term_width) - 4 ))
  [[ "$w" -lt 30 ]] && w=30

  local inner=$(( w - 2 ))  # inside the box borders

  echo ""
  echo -e "  ${WHITE}┌$(hr '─' "$inner")┐${NC}"
  printf "  ${WHITE}│${NC}  ${BOLD}${BRIGHT_CYAN}dev-harness${NC}  ${DIM}v${HARNESS_VERSION}${NC}%*s${WHITE}│${NC}\n" $(( inner - 17 - ${#HARNESS_VERSION} )) ""
  if [[ "$count" -gt 0 ]]; then
    local stats_str="${count} sessions | \$${total_cost} total"
    printf "  ${WHITE}│${NC}  ${DIM}%s${NC}%*s${WHITE}│${NC}\n" "$stats_str" $(( inner - 2 - ${#stats_str} )) ""
  fi
  echo -e "  ${WHITE}└$(hr '─' "$inner")┘${NC}"
  echo -e "  ${DIM}$(basename "$(pwd)")${NC}"
}

# --- Progress indicator ------------------------------------------------------
# Displays: ● Structurer  ▸  ◉ Planner  ▸  ○ Builder  ▸  ○ QA
show_progress() {
  local current="$1"
  shift
  local phase_names=("$@")
  local line="  "

  for i in "${!phase_names[@]}"; do
    local idx=$((i + 1))
    if [[ $idx -lt $current ]]; then
      line+="${BRIGHT_GREEN}●${NC} ${DIM}${phase_names[$i]}${NC}"
    elif [[ $idx -eq $current ]]; then
      line+="${BRIGHT_CYAN}◉${NC} ${BOLD}${phase_names[$i]}${NC}"
    else
      line+="${DIM}○ ${phase_names[$i]}${NC}"
    fi
    if [[ $idx -lt ${#phase_names[@]} ]]; then
      line+="  ${DIM}▸${NC}  "
    fi
  done

  echo -e "$line"
}

# --- Interactive mode --------------------------------------------------------
run_interactive() {
  show_banner
  show_status

  local has_plan=false
  local has_build=false
  [[ -f "$HARNESS_DIR/plan.md" ]] && has_plan=true
  [[ -f "$HARNESS_DIR/build-result.md" ]] && has_build=true

  while true; do
    echo -e "  ${BOLD}What do you want to do?${NC}"
    echo ""

    local struct_hint=""
    if [[ -f "$HARNESS_DIR/structure.md" ]]; then
      local struct_age=$(( ( $(date +%s) - $(portable_mtime "$HARNESS_DIR/structure.md") ) / 60 ))
      if [[ "$struct_age" -lt "${HARNESS_STRUCTURE_TTL}" ]]; then
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
    echo -e "    ${BRIGHT_CYAN}6${NC}  ${BOLD}Sessions${NC}            ${DIM}past runs & costs${NC}"
    echo -e "    ${BRIGHT_CYAN}7${NC}  ${BOLD}Clean${NC}               ${DIM}wipe .harness/${NC}"

    # Show re-run option if there's a previous task
    if [[ -f "$HARNESS_DIR/task.txt" ]]; then
      local last_task
      last_task=$(cat "$HARNESS_DIR/task.txt")
      local short_task="${last_task:0:35}"
      [[ ${#last_task} -gt 35 ]] && short_task+="..."
      echo -e "    ${BRIGHT_CYAN}r${NC}  ${BOLD}Re-run${NC}             ${DIM}${short_task}${NC}"
    fi

    echo -e "    ${DIM}q  Quit${NC}"
    echo ""

    if [[ -n "$HARNESS_MODEL" ]]; then
      echo -e "  ${DIM}model: ${HARNESS_MODEL}${NC}"
      echo ""
    fi

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

        # Offer to reuse existing structure if it's still fresh
        if [[ -f "$HARNESS_DIR/structure.md" ]] && ! $FRESH; then
          local i_struct_age=$(( ( $(date +%s) - $(portable_mtime "$HARNESS_DIR/structure.md") ) / 60 ))
          if [[ "$i_struct_age" -lt "${HARNESS_STRUCTURE_TTL}" ]]; then
            echo -e "  ${DIM}Existing structure.md is ${i_struct_age}m old (TTL: ${HARNESS_STRUCTURE_TTL}m)${NC}"
            echo -ne "  Reuse structure? ${DIM}[Y/n]${NC} "
            read -r reuse_struct
            if [[ "$reuse_struct" != "n" && "$reuse_struct" != "N" ]]; then
              NO_STRUCTURE=true
              echo ""
              ok "Reusing existing structure"
            else
              echo ""
              FRESH=true
              ok "Will re-run structurer"
            fi
            echo ""
          fi
        fi

        local cost_est
        cost_est=$(estimate_cost "full")
        if [[ -n "$cost_est" ]]; then
          echo -e "  ${DIM}Estimated cost: ${cost_est}${NC}"
        fi
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
        local cost_est2
        cost_est2=$(estimate_cost "plan-only")
        if [[ -n "$cost_est2" ]]; then
          echo -e "  ${DIM}Estimated cost: ${cost_est2}${NC}"
        fi
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
      r|R)
        if [[ -f "$HARNESS_DIR/task.txt" ]]; then
          TASK=$(cat "$HARNESS_DIR/task.txt")
          echo ""
          ok "Re-running: ${BOLD}$TASK${NC}"
          echo ""
          history_add "full" "$TASK"
          return 0
        else
          warn "No previous task to re-run."
          echo ""
        fi
        ;;
      q|Q|quit|exit)
        echo ""
        dim "bye."
        echo ""
        exit 0
        ;;
      *)
        warn "Pick 1-7, r (re-run), or q."
        echo ""
        ;;
    esac
  done
}

# --- Launch interactive mode if no task/flags given --------------------------
INTERACTIVE=false
if [[ -z "$TASK" && $PLAN_ONLY == false && $SKIP_PLAN == false && $BUILDER_ONLY == false && $QA_ONLY == false && $RESUME == false ]]; then
  INTERACTIVE=true
  run_interactive
fi

# --- Setup .harness/ ---------------------------------------------------------
mkdir -p "$HARNESS_DIR"
echo "# Harness run: $TIMESTAMP" > "$LOG_FILE"
log "Task: $TASK"
log "Flags: plan_only=$PLAN_ONLY skip_plan=$SKIP_PLAN builder_only=$BUILDER_ONLY qa_only=$QA_ONLY quiet=$QUIET model=$HARNESS_MODEL max_turns=$HARNESS_MAX_TURNS"

# --- Build codebase preambles ------------------------------------------------
# Full: for Structurer and Planner (README, stack hints, directory listing)
build_full_preamble() {
  local preamble="You are working inside a software project.\n\n"

  if [[ -f "CLAUDE.md" ]]; then
    preamble+="## Project guidance (CLAUDE.md)\n\n"
    preamble+="$(cat CLAUDE.md)\n\n"
  fi

  if [[ -f "README.md" ]]; then
    preamble+="## Project README\n\n"
    preamble+="$(head -100 README.md)\n\n"
  elif [[ -f "README" ]]; then
    preamble+="## Project README\n\n"
    preamble+="$(head -100 README)\n\n"
  fi

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

  preamble+="## Top-level directory listing\n\n"
  preamble+="$(ls -1 | head -40)\n"

  echo -e "$preamble"
}

# Light: for Builder (CLAUDE.md + stack hints, no README or directory listing)
build_light_preamble() {
  local preamble="You are working inside a software project.\n\n"

  if [[ -f "CLAUDE.md" ]]; then
    preamble+="## Project guidance (CLAUDE.md)\n\n"
    preamble+="$(cat CLAUDE.md)\n\n"
  fi

  local stack_hints=""
  [[ -f "package.json" ]]       && stack_hints+="- Node.js/JavaScript\n"
  [[ -f "tsconfig.json" ]]      && stack_hints+="- TypeScript\n"
  [[ -f "requirements.txt" || -f "pyproject.toml" || -f "Pipfile" ]] && stack_hints+="- Python\n"
  [[ -f "go.mod" ]]             && stack_hints+="- Go\n"
  [[ -f "Cargo.toml" ]]         && stack_hints+="- Rust\n"
  [[ -f "Gemfile" ]]            && stack_hints+="- Ruby\n"
  [[ -f "pom.xml" || -f "build.gradle" ]] && stack_hints+="- Java\n"

  if [[ -n "$stack_hints" ]]; then
    preamble+="## Stack\n\n$stack_hints\n"
  fi

  echo -e "$preamble"
}

# Minimal: for QA (CLAUDE.md only — the QA agent reads files directly)
build_minimal_preamble() {
  local preamble="You are working inside a software project.\n\n"

  if [[ -f "CLAUDE.md" ]]; then
    preamble+="## Project guidance (CLAUDE.md)\n\n"
    preamble+="$(cat CLAUDE.md)\n\n"
  fi

  echo -e "$preamble"
}

# Truncate an artifact to first N lines for token savings
truncate_artifact() {
  local file="$1"
  local max_lines="${2:-80}"
  local content
  content=$(head -"$max_lines" "$file")
  local total_lines
  total_lines=$(wc -l < "$file" | tr -d ' ')
  if [[ "$total_lines" -gt "$max_lines" ]]; then
    content+=$'\n\n'"[... truncated — ${total_lines} total lines, showing first ${max_lines}]"
  fi
  echo "$content"
}

# --- Model selection for a phase ---------------------------------------------
get_phase_model() {
  local phase_name="$1"
  local model=""

  case "$phase_name" in
    Structurer) model="${HARNESS_MODEL_STRUCTURER:-$HARNESS_MODEL}" ;;
    Planner)    model="${HARNESS_MODEL_PLANNER:-$HARNESS_MODEL}" ;;
    Builder)    model="${HARNESS_MODEL_BUILDER:-$HARNESS_MODEL}" ;;
    QA)         model="${HARNESS_MODEL_QA:-$HARNESS_MODEL}" ;;
    *)          model="$HARNESS_MODEL" ;;
  esac

  echo "$model"
}

# --- Phase runner with error recovery ----------------------------------------
run_phase() {
  local name="$1"
  local prompt="$2"
  local output_file="$3"
  local phase_idx="${4:-0}"
  local total_phases="${5:-0}"

  # Show progress indicator
  if [[ "$total_phases" -gt 0 && ${#PHASE_NAMES[@]} -gt 0 ]]; then
    show_progress "$phase_idx" "${PHASE_NAMES[@]}"
    echo ""
  fi

  local phase_label="$name"
  if [[ "$total_phases" -gt 0 ]]; then
    phase_label="$name ${DIM}[$phase_idx/$total_phases]${NC}"
  fi

  phase "$phase_label"
  log "Starting phase: $name [$phase_idx/$total_phases]"

  # Build claude CLI args
  local model
  model=$(get_phase_model "$name")
  if [[ -n "$model" ]]; then
    ts "Model: ${BOLD}$model${NC}"
  fi

  local max_turns_val="$HARNESS_MAX_TURNS"
  if [[ "$max_turns_val" -gt 0 ]]; then
    ts "Max turns: ${BOLD}$max_turns_val${NC}"
  fi

  ts "Connecting to Claude..."

  # Retry loop for error recovery
  local success=false
  while ! $success; do
    local start_time=$SECONDS

    if $QUIET; then
      local -a quiet_args=(-p --dangerously-skip-permissions)
      [[ -n "$model" ]] && quiet_args+=(--model "$model")
      [[ "$max_turns_val" -gt 0 ]] && quiet_args+=(--max-turns "$max_turns_val")

      if claude "${quiet_args[@]}" "$prompt" > "$output_file" 2>>"$LOG_FILE"; then
        local elapsed=$(( SECONDS - start_time ))
        ts "${BRIGHT_GREEN}✓${NC} $name completed in ${elapsed}s — output: $output_file"
        log "$name completed in ${elapsed}s"
        # Reprint progress bar after phase completion
        if [[ "$total_phases" -gt 0 && ${#PHASE_NAMES[@]} -gt 0 ]]; then
          echo ""
          show_progress "$(( phase_idx + 1 ))" "${PHASE_NAMES[@]}"
        fi
        success=true
      else
        local elapsed=$(( SECONDS - start_time ))
        ts "${BRIGHT_RED}✗${NC} $name failed after ${elapsed}s"
        log "$name FAILED after ${elapsed}s"
        if ! _handle_failure "$name"; then
          return 0  # skip
        fi
        # else: retry (loop continues)
      fi
    else
      local -a stream_args=(-p --verbose --output-format stream-json --dangerously-skip-permissions)
      [[ -n "$model" ]] && stream_args+=(--model "$model")
      [[ "$max_turns_val" -gt 0 ]] && stream_args+=(--max-turns "$max_turns_val")

      echo ""
      if claude "${stream_args[@]}" "$prompt" \
        2>>"$LOG_FILE" | python3 "$SCRIPT_DIR/stream_processor.py" \
          "$output_file" "$name" "$SESSION_FILE" "${model:-default}"; then
        local elapsed=$(( SECONDS - start_time ))
        echo ""
        ts "${BRIGHT_GREEN}✓${NC} $name completed in ${elapsed}s — saved: ${DIM}$output_file${NC}"
        log "$name completed in ${elapsed}s"
        # Reprint progress bar after phase completion
        if [[ "$total_phases" -gt 0 && ${#PHASE_NAMES[@]} -gt 0 ]]; then
          echo ""
          show_progress "$(( phase_idx + 1 ))" "${PHASE_NAMES[@]}"
        fi
        success=true
      else
        local elapsed=$(( SECONDS - start_time ))
        echo ""
        ts "${BRIGHT_RED}✗${NC} $name failed after ${elapsed}s"
        log "$name FAILED after ${elapsed}s"
        if ! _handle_failure "$name"; then
          return 0  # skip
        fi
        # else: retry (loop continues)
        ts "Retrying $name..."
      fi
    fi
  done
}

# Returns 0 = retry, 1 = skip. Exits on quit.
_handle_failure() {
  local name="$1"

  # Non-interactive: hard exit
  if [[ ! -t 0 ]]; then
    err "$name failed. Check $LOG_FILE for details."
    exit 1
  fi

  echo ""
  echo -e "  ${BOLD}$name failed.${NC} What do you want to do?"
  echo ""
  echo -e "    ${BRIGHT_CYAN}r${NC}  Retry this phase"
  echo -e "    ${BRIGHT_CYAN}s${NC}  Skip to next phase"
  echo -e "    ${BRIGHT_CYAN}q${NC}  Quit"
  echo ""
  echo -ne "  ${BRIGHT_CYAN}>${NC} "
  read -r recovery_choice

  case "$recovery_choice" in
    r|R)
      return 0  # retry
      ;;
    s|S)
      warn "Skipping $name"
      return 1  # skip
      ;;
    *)
      err "Aborting."
      exit 1
      ;;
  esac
}

# --- Dry-run preview ---------------------------------------------------------
show_dry_run() {
  echo ""
  echo -e "  ${BOLD}${BRIGHT_CYAN}Dry run${NC} — showing what would execute"
  echo ""
  echo -e "  ${BOLD}Task:${NC}   $TASK"
  echo -e "  ${BOLD}Phases:${NC} ${#PHASE_NAMES[@]}"
  if [[ -n "$HARNESS_MODEL" ]]; then
    echo -e "  ${BOLD}Model:${NC}  $HARNESS_MODEL"
  fi
  if [[ "$HARNESS_MAX_TURNS" -gt 0 ]]; then
    echo -e "  ${BOLD}Turns:${NC}  $HARNESS_MAX_TURNS per phase"
  fi
  echo ""

  for i in "${!PHASE_NAMES[@]}"; do
    local idx=$((i + 1))
    local pname="${PHASE_NAMES[$i]}"
    local model
    model=$(get_phase_model "$pname")
    local model_hint=""
    [[ -n "$model" ]] && model_hint=" ${DIM}(${model})${NC}"

    echo -e "    ${BRIGHT_CYAN}${idx}${NC}  ${BOLD}$pname${NC}${model_hint}"
  done

  echo ""
  local cost_est
  cost_est=$(estimate_cost "$RUN_MODE")
  if [[ -n "$cost_est" ]]; then
    echo -e "  ${DIM}Estimated cost: ${cost_est}${NC}"
  fi
  echo ""
  dim "Run without --dry-run to execute."
  echo ""
  exit 0
}

# =============================================================================
# Phase definitions (with token-optimized prompts)
# =============================================================================
run_structurer() {
  # Cap structurer turns to save tokens (override only if not already set lower)
  local saved_max_turns="$HARNESS_MAX_TURNS"
  if [[ "$HARNESS_MAX_TURNS" -eq 0 || "$HARNESS_MAX_TURNS" -gt 15 ]]; then
    HARNESS_MAX_TURNS=15
  fi

  local prompt
  prompt=$(cat <<PROMPT
$(build_full_preamble)

## Your role: Structurer

You are the Structurer agent in a multi-agent development pipeline. Your job is to analyze the codebase and produce a structured map that later agents will use.

## Task

The user wants to accomplish the following:

$TASK

## Instructions

Focus only on areas relevant to the task. Do NOT exhaustively catalog the entire repo.

1. Identify which files, modules, and components are relevant to the task.
2. Note any patterns, conventions, or architectural decisions visible in the relevant code.
3. Identify test infrastructure and build tooling relevant to the task.
4. Flag any potential risks or dependencies that could affect the task.
5. Keep output concise — no more than 200 lines. Later agents only need what's relevant.

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

  # Restore original max turns
  HARNESS_MAX_TURNS="$saved_max_turns"
}

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
$(build_full_preamble)

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

run_builder() {
  local plan
  if [[ -f "$HARNESS_DIR/plan.md" ]]; then
    plan=$(cat "$HARNESS_DIR/plan.md")
  else
    err "No plan file found at $HARNESS_DIR/plan.md — run Planner first."
    exit 1
  fi

  # Token optimization: truncated structure summary instead of full artifact
  local structure_section=""
  if [[ -f "$HARNESS_DIR/structure.md" ]]; then
    local structure_summary
    structure_summary=$(truncate_artifact "$HARNESS_DIR/structure.md" 80)
    structure_section="## Codebase structure (from Structurer — summary)

$structure_summary"
  fi

  local prompt
  prompt=$(cat <<PROMPT
$(build_light_preamble)

## Your role: Builder

You are the Builder agent in a multi-agent development pipeline. The Structurer analyzed the codebase and the Planner produced an implementation plan. Your job is to execute the plan by making actual code changes.

## Task

The user wants to accomplish the following:

$TASK

$structure_section

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

run_qa() {
  local build_result=""
  if [[ -f "$HARNESS_DIR/build-result.md" ]]; then
    build_result=$(cat "$HARNESS_DIR/build-result.md")
  fi

  # Token optimization: truncated plan, no structure at all
  local plan_summary=""
  if [[ -f "$HARNESS_DIR/plan.md" ]]; then
    plan_summary=$(truncate_artifact "$HARNESS_DIR/plan.md" 60)
  fi

  local prompt
  prompt=$(cat <<PROMPT
$(build_minimal_preamble)

## Your role: QA Reviewer

You are the QA agent in a multi-agent development pipeline. The Builder has made code changes. Your job is to thoroughly review everything and ensure quality.

## Task that was implemented

$TASK

## Implementation plan (summary)

$plan_summary

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
$RESUME && RUN_MODE="resume"

# Log to history if invoked from CLI (interactive mode logs its own)
if [[ -n "$TASK" && ! -f "$HARNESS_DIR/.interactive" ]]; then
  history_add "$RUN_MODE" "$TASK"
fi

# --- Compute total phases and set up session ----------------------------------
TOTAL_PHASES=4
CURRENT_PHASE=0
PHASE_NAMES=()

if $QA_ONLY; then
  TOTAL_PHASES=1
  PHASE_NAMES=("QA")
elif $BUILDER_ONLY; then
  TOTAL_PHASES=1
  PHASE_NAMES=("Builder")
elif $SKIP_PLAN; then
  TOTAL_PHASES=2
  PHASE_NAMES=("Builder" "QA")
elif $PLAN_ONLY; then
  TOTAL_PHASES=2
  PHASE_NAMES=("Structurer" "Planner")
else
  TOTAL_PHASES=4
  PHASE_NAMES=("Structurer" "Planner" "Builder" "QA")
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
    'version': sys.argv[4],
    'model': sys.argv[5],
    'cwd': os.getcwd(),
    'phases': []
}
with open(sys.argv[6], 'w') as f:
    json.dump(session, f, indent=2)
" "$TASK" "$RUN_MODE" "$TIMESTAMP" "$HARNESS_VERSION" "${HARNESS_MODEL:-default}" "$SESSION_FILE"

RUN_START=$SECONDS

# --- Check if structurer can be skipped ---------------------------------------
SKIP_STRUCTURER=false
STRUCTURE_AGE_MIN=""

# --no-structure: always skip the structurer
if $NO_STRUCTURE; then
  SKIP_STRUCTURER=true
  if [[ -f "$HARNESS_DIR/structure.md" ]]; then
    STRUCTURE_AGE_MIN=$(( ( $(date +%s) - $(portable_mtime "$HARNESS_DIR/structure.md") ) / 60 ))
  fi
elif [[ -f "$HARNESS_DIR/structure.md" ]] && ! $FRESH; then
  STRUCTURE_AGE_MIN=$(( ( $(date +%s) - $(portable_mtime "$HARNESS_DIR/structure.md") ) / 60 ))
  if [[ "$STRUCTURE_AGE_MIN" -lt "${HARNESS_STRUCTURE_TTL}" ]]; then
    SKIP_STRUCTURER=true
  fi
fi

# Adjust phase counts if skipping structurer
if $SKIP_STRUCTURER; then
  if $PLAN_ONLY; then
    TOTAL_PHASES=1
    PHASE_NAMES=("Planner")
  elif ! $QA_ONLY && ! $BUILDER_ONLY && ! $SKIP_PLAN && ! $RESUME; then
    TOTAL_PHASES=3
    PHASE_NAMES=("Planner" "Builder" "QA")
  fi
fi

# --- Handle resume -----------------------------------------------------------
if $RESUME; then
  LAST_SESSION=$(python3 -c "
import json, glob, os
sessions_dir = '$SESSIONS_DIR'
files = sorted(glob.glob(os.path.join(sessions_dir, '*.json')))
for f in reversed(files):
    try:
        with open(f) as fh:
            s = json.load(fh)
        phases = [p['name'] for p in s.get('phases', [])]
        all_phases = ['Structurer', 'Planner', 'Builder', 'QA']
        for p in all_phases:
            if p not in phases:
                print(p)
                break
        else:
            print('done')
        break
    except: continue
else:
    print('')
" 2>/dev/null)

  if [[ -z "$LAST_SESSION" ]]; then
    warn "No previous session found. Starting full pipeline."
    RESUME=false
  elif [[ "$LAST_SESSION" == "done" ]]; then
    ok "Previous session completed all phases. Nothing to resume."
    exit 0
  else
    ts "Resuming from: ${BOLD}$LAST_SESSION${NC}"
    case "$LAST_SESSION" in
      Structurer) PHASE_NAMES=("Structurer" "Planner" "Builder" "QA"); TOTAL_PHASES=4 ;;
      Planner)    PHASE_NAMES=("Planner" "Builder" "QA"); TOTAL_PHASES=3 ;;
      Builder)    PHASE_NAMES=("Builder" "QA"); TOTAL_PHASES=2 ;;
      QA)         PHASE_NAMES=("QA"); TOTAL_PHASES=1 ;;
    esac
  fi
fi

# --- Dry-run check -----------------------------------------------------------
if $DRY_RUN; then
  show_dry_run
fi

# --- Show cost estimate before running ----------------------------------------
if [[ -t 1 ]]; then
  cost_est=$(estimate_cost "$RUN_MODE")
  if [[ -n "$cost_est" ]]; then
    echo -e "  ${DIM}Estimated cost: ${cost_est}${NC}"
    echo ""
  fi
fi

# --- Execute pipeline ---------------------------------------------------------
if $RESUME; then
  for i in "${!PHASE_NAMES[@]}"; do
    CURRENT_PHASE=$((i + 1))
    case "${PHASE_NAMES[$i]}" in
      Structurer) run_structurer ;;
      Planner)    run_planner ;;
      Builder)    run_builder ;;
      QA)         run_qa ;;
    esac
  done
elif $QA_ONLY; then
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

QA_VERDICT="--"
if [[ -f "$HARNESS_DIR/qa-report.md" ]]; then
  QA_VERDICT=$(grep -oEi '(PASS WITH NOTES|PASS|FAIL)' "$HARNESS_DIR/qa-report.md" | head -1 || echo "--")
  [[ -z "$QA_VERDICT" ]] && QA_VERDICT="--"
fi

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
if [[ $TOTAL_ELAPSED -ge 60 ]]; then
  DURATION_FMT="$(( TOTAL_ELAPSED / 60 ))m$(( TOTAL_ELAPSED % 60 ))s"
else
  DURATION_FMT="${TOTAL_ELAPSED}s"
fi

read -r TOTAL_COST_STR TOTAL_TOKENS_STR < <(python3 -c "
import json
try:
    with open('$SESSION_FILE') as f:
        s = json.load(f)
    cost = s.get('total_cost_usd', 0)
    tokens = sum(p.get('total_tokens', 0) for p in s.get('phases', []))
    if tokens >= 1000:
        t_str = f'{tokens / 1000:.1f}K'
    else:
        t_str = str(tokens)
    print(f'\${cost:.4f} {t_str}')
except: print('\$0.0000 0')
" 2>/dev/null)

QA_COLOR="$DIM"
if [[ "$QA_VERDICT" == "PASS" || "$QA_VERDICT" == "PASS WITH NOTES" ]]; then QA_COLOR="$BRIGHT_GREEN"
elif [[ "$QA_VERDICT" == "FAIL" ]]; then QA_COLOR="$BRIGHT_RED"
fi

# Final progress bar — all phases complete
if [[ ${#PHASE_NAMES[@]} -gt 0 ]]; then
  echo ""
  show_progress "$(( ${#PHASE_NAMES[@]} + 1 ))" "${PHASE_NAMES[@]}"
fi

BOX_W=$(( $(term_width) - 4 ))
[[ "$BOX_W" -lt 40 ]] && BOX_W=40
BOX_INNER=$(( BOX_W - 2 ))

# Truncate task to fit inside the box
TASK_MAX=$(( BOX_INNER - 12 ))
TASK_DISPLAY="${TASK:0:$TASK_MAX}"
[[ ${#TASK} -gt $TASK_MAX ]] && TASK_DISPLAY+="..."

echo ""
echo -e "  ${WHITE}┌─ Run complete $(hr '─' $(( BOX_INNER - 15 )))┐${NC}"
printf "  ${WHITE}│${NC}  ${BOLD}Task:${NC} %-*s ${WHITE}│${NC}\n" $(( BOX_INNER - 8 )) "$TASK_DISPLAY"
echo -e "  ${WHITE}│$(printf '%*s' "$BOX_INNER" '')│${NC}"
printf "  ${WHITE}│${NC}  Duration: %-10s  Cost: %-12s ${WHITE}%*s│${NC}\n" "$DURATION_FMT" "$TOTAL_COST_STR" $(( BOX_INNER - 40 > 0 ? BOX_INNER - 40 : 0 )) ""
printf "  ${WHITE}│${NC}  Phases:   %-10s  QA:   ${QA_COLOR}%-12s${NC} ${WHITE}%*s│${NC}\n" "$TOTAL_PHASES/$TOTAL_PHASES" "$QA_VERDICT" $(( BOX_INNER - 40 > 0 ? BOX_INNER - 40 : 0 )) ""
printf "  ${WHITE}│${NC}  Tokens:   %-10s  Model: %-11s ${WHITE}%*s│${NC}\n" "$TOTAL_TOKENS_STR" "${HARNESS_MODEL:-default}" $(( BOX_INNER - 40 > 0 ? BOX_INNER - 40 : 0 )) ""
echo -e "  ${WHITE}│$(printf '%*s' "$BOX_INNER" '')│${NC}"

# Per-phase breakdown table
python3 -c "
import json, shutil
try:
    tw = shutil.get_terminal_size((80, 24)).columns
    inner = tw - 6  # 2 indent + 2 border + 2 padding
    if inner < 36: inner = 36
    with open('$SESSION_FILE') as f:
        s = json.load(f)
    phases = s.get('phases', [])
    if phases:
        hdr = '%-12s %7s %8s %9s %6s' % ('Phase', 'Time', 'Tokens', 'Cost', 'Tools')
        pad = inner - len(hdr) - 2
        if pad < 0: pad = 0
        print('  \033[1;37m│\033[0m  \033[2m%s\033[0m%s \033[1;37m│\033[0m' % (hdr, ' ' * pad))
        sep = '%-12s %7s %8s %9s %6s' % ('─'*12, '─'*7, '─'*8, '─'*9, '─'*6)
        print('  \033[1;37m│\033[0m  \033[2m%s\033[0m%s \033[1;37m│\033[0m' % (sep, ' ' * pad))
        for p in phases:
            name = p.get('name', '?')
            dur = p.get('duration_s', 0)
            tok = p.get('total_tokens', 0)
            cost = p.get('cost_usd', 0)
            tools = p.get('tools_used', 0)
            tok_s = f'{tok/1000:.1f}K' if tok >= 1000 else str(tok)
            dur_s = f'{dur//60:.0f}m{dur%60:02.0f}s' if dur >= 60 else f'{dur:.0f}s'
            row = '%-12s %7s %8s   \$%6.4f  %5d' % (name, dur_s, tok_s, cost, tools)
            print('  \033[1;37m│\033[0m  %s%s \033[1;37m│\033[0m' % (row, ' ' * pad))
        print('  \033[1;37m│\033[0m%s\033[1;37m│\033[0m' % (' ' * (inner + 2)))
except: pass
" 2>/dev/null

# Artifact dots
ARTIFACTS_LINE=""
for artifact in structure.md plan.md build-result.md qa-report.md; do
  if [[ -f "$HARNESS_DIR/$artifact" ]]; then
    ARTIFACTS_LINE+="${GREEN}●${NC} $artifact  "
  else
    ARTIFACTS_LINE+="${DIM}○ $artifact${NC}  "
  fi
done
echo -e "  ${WHITE}│${NC}  ${ARTIFACTS_LINE}${WHITE}│${NC}"
echo -e "  ${WHITE}└$(hr '─' "$BOX_INNER")┘${NC}"

# --- Suggested next steps -----------------------------------------------------
show_next_steps() {
  local steps=()

  if $PLAN_ONLY; then
    steps+=("Review plan:     ${CYAN}cat $HARNESS_DIR/plan.md${NC}")
    steps+=("Execute plan:    ${CYAN}harness --skip-plan${NC}")
  elif [[ "$QA_VERDICT" == "PASS" || "$QA_VERDICT" == "PASS WITH NOTES" ]]; then
    steps+=("Review changes:  ${CYAN}git diff${NC}")
    steps+=("Commit:          ${CYAN}git add -p && git commit${NC}")
  elif [[ "$QA_VERDICT" == "FAIL" ]]; then
    steps+=("Check report:    ${CYAN}cat $HARNESS_DIR/qa-report.md${NC}")
    steps+=("Re-run QA:       ${CYAN}harness --qa-only${NC}")
    steps+=("Retry build:     ${CYAN}harness --builder-only${NC}")
  elif $BUILDER_ONLY; then
    steps+=("Run QA:          ${CYAN}harness --qa-only${NC}")
  elif $QA_ONLY; then
    if [[ "$QA_VERDICT" == "PASS" || "$QA_VERDICT" == "PASS WITH NOTES" ]]; then
      steps+=("Review changes:  ${CYAN}git diff${NC}")
      steps+=("Commit:          ${CYAN}git add -p && git commit${NC}")
    else
      steps+=("Fix and retry:   ${CYAN}harness --builder-only${NC}")
    fi
  else
    steps+=("Review changes:  ${CYAN}git diff${NC}")
    steps+=("View artifacts:  ${CYAN}harness${NC}  ${DIM}(interactive menu)${NC}")
  fi

  local ns_w=$(( $(term_width) - 4 ))
  [[ "$ns_w" -lt 30 ]] && ns_w=30
  local ns_inner=$(( ns_w - 2 ))

  echo ""
  echo -e "  ${WHITE}┌─ Next steps $(hr '─' $(( ns_inner - 13 )))┐${NC}"
  for step in "${steps[@]}"; do
    echo -e "  ${WHITE}│${NC}  $step  ${WHITE}│${NC}"
  done
  echo -e "  ${WHITE}└$(hr '─' "$ns_inner")┘${NC}"
  echo ""
}

# --- End-of-run summary: what was done ----------------------------------------
show_run_summary() {
  local sum_w=$(( $(term_width) - 4 ))
  [[ "$sum_w" -lt 30 ]] && sum_w=30
  local sum_inner=$(( sum_w - 2 ))
  local wrap_w=$(( sum_inner - 4 ))

  echo ""
  echo -e "  ${WHITE}┌─ What was done $(hr '─' $(( sum_inner - 16 )))┐${NC}"

  # Extract plan summary (first non-empty, non-heading line from plan.md)
  if [[ -f "$HARNESS_DIR/plan.md" ]]; then
    local plan_summary
    plan_summary=$(grep -m3 -v '^#\|^$\|^---' "$HARNESS_DIR/plan.md" 2>/dev/null | head -3)
    if [[ -n "$plan_summary" ]]; then
      echo -e "  ${WHITE}│${NC}"
      echo -e "  ${WHITE}│${NC}  ${BOLD}Plan:${NC}"
      while IFS= read -r pline; do
        echo -e "  ${WHITE}│${NC}    ${DIM}$(echo "$pline" | cut -c1-"$wrap_w")${NC}  ${WHITE}│${NC}"
      done <<< "$plan_summary"
    fi
  fi

  # Extract changes made from build-result.md
  if [[ -f "$HARNESS_DIR/build-result.md" ]]; then
    local changes
    changes=$(sed -n '/^### Changes made/,/^###/{/^###/!p;}' "$HARNESS_DIR/build-result.md" 2>/dev/null | grep -v '^$' | head -8)
    if [[ -n "$changes" ]]; then
      echo -e "  ${WHITE}│${NC}"
      echo -e "  ${WHITE}│${NC}  ${BOLD}Changes:${NC}"
      while IFS= read -r cline; do
        echo -e "  ${WHITE}│${NC}    ${DIM}$(echo "$cline" | cut -c1-"$wrap_w")${NC}  ${WHITE}│${NC}"
      done <<< "$changes"
    fi
  fi

  # Extract QA verdict and key findings from qa-report.md
  if [[ -f "$HARNESS_DIR/qa-report.md" ]]; then
    local qa_summary
    qa_summary=$(sed -n '/^### Review summary\|^### Final assessment/,/^###/{/^###/!p;}' "$HARNESS_DIR/qa-report.md" 2>/dev/null | grep -v '^$' | head -4)
    if [[ -n "$qa_summary" ]]; then
      echo -e "  ${WHITE}│${NC}"
      echo -e "  ${WHITE}│${NC}  ${BOLD}QA:${NC}"
      while IFS= read -r qline; do
        echo -e "  ${WHITE}│${NC}    ${DIM}$(echo "$qline" | cut -c1-"$wrap_w")${NC}  ${WHITE}│${NC}"
      done <<< "$qa_summary"
    fi
  fi

  echo -e "  ${WHITE}│${NC}"
  echo -e "  ${WHITE}└$(hr '─' "$sum_inner")┘${NC}"
}

# Only show run summary if we have artifacts to summarize
if [[ -f "$HARNESS_DIR/plan.md" || -f "$HARNESS_DIR/build-result.md" || -f "$HARNESS_DIR/qa-report.md" ]]; then
  show_run_summary
fi

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

  relaunch_args=()
  [[ -n "$HARNESS_MODEL" ]] && relaunch_args+=(--model "$HARNESS_MODEL")
  [[ "$HARNESS_MAX_TURNS" -gt 0 ]] 2>/dev/null && relaunch_args+=(--max-turns "$HARNESS_MAX_TURNS")
  $QUIET && relaunch_args+=(--quiet)
  exec "$SCRIPT_DIR/harness.sh" "${relaunch_args[@]}"
fi
