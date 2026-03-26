#!/usr/bin/env python3
"""
Stream processor for dev-harness.
Reads claude --output-format stream-json from stdin, displays live tool
calls and text, writes the final result to an artifact file, and appends
phase cost/duration to the session ledger.
"""

import sys
import json
import os

# ANSI colors
CYAN = "\033[0;36m"
BRIGHT_CYAN = "\033[1;36m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
NC = "\033[0m"

# Tool display names and icons
TOOL_DISPLAY = {
    "Read": ("Read", "file_path"),
    "Edit": ("Edit", "file_path"),
    "Write": ("Write", "file_path"),
    "Glob": ("Glob", "pattern"),
    "Grep": ("Grep", "pattern"),
    "Bash": ("Bash", "command"),
    "WebFetch": ("Fetch", "url"),
    "WebSearch": ("Search", "query"),
    "NotebookEdit": ("Notebook", "file_path"),
}


def format_tool_detail(name, inp):
    """Extract a short, readable detail string from tool input."""
    if name in TOOL_DISPLAY:
        _, key = TOOL_DISPLAY[name]
        val = inp.get(key, "")
    else:
        # fallback: try common keys
        val = inp.get("file_path", inp.get("command", inp.get("pattern", "")))

    if not val:
        return ""

    val = str(val)

    # For file paths, show just the filename + parent
    if "/" in val and name in ("Read", "Edit", "Write", "NotebookEdit"):
        parts = val.rstrip("/").split("/")
        val = "/".join(parts[-2:]) if len(parts) >= 2 else parts[-1]

    # For bash commands, show first 55 chars
    if name == "Bash":
        val = val.split("\n")[0]  # first line only
        if len(val) > 55:
            val = val[:52] + "..."

    # For grep/glob patterns, show as-is but truncate
    if len(val) > 60:
        val = val[:57] + "..."

    return val


def main():
    output_file = sys.argv[1] if len(sys.argv) > 1 else None
    phase_name = sys.argv[2] if len(sys.argv) > 2 else "unknown"
    session_file = sys.argv[3] if len(sys.argv) > 3 else None

    final_text = ""
    duration_ms = 0
    cost_usd = 0.0
    tool_count = 0
    text_started = False

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        etype = event.get("type", "")

        if etype == "assistant":
            content = event.get("message", {}).get("content", [])
            for block in content:
                btype = block.get("type", "")

                if btype == "tool_use":
                    name = block.get("name", "?")
                    inp = block.get("input", {})
                    detail = format_tool_detail(name, inp)
                    display_name = TOOL_DISPLAY.get(name, (name, ""))[0]

                    # If we were streaming text, add a newline separator
                    if text_started:
                        sys.stdout.write("\n")
                        text_started = False

                    print(
                        f"  {BRIGHT_CYAN}> {CYAN}{display_name:<9}{NC}"
                        f" {DIM}{detail}{NC}",
                        flush=True,
                    )
                    tool_count += 1

                elif btype == "text":
                    text = block.get("text", "")
                    if text:
                        if not text_started and tool_count > 0:
                            # Visual separator between tools and final text
                            print(f"\n  {DIM}{'─' * 50}{NC}\n", flush=True)
                        text_started = True
                        sys.stdout.write(text)
                        sys.stdout.flush()

        elif etype == "result":
            final_text = event.get("result", "")
            duration_ms = event.get("duration_ms", 0)
            cost_usd = event.get("total_cost_usd", 0.0)

        # Ignore system, user, rate_limit_event types silently

    # Ensure final newline after streamed text
    if text_started:
        sys.stdout.write("\n")

    # Write artifact file
    if output_file and final_text:
        os.makedirs(os.path.dirname(output_file) or ".", exist_ok=True)
        with open(output_file, "w") as f:
            f.write(final_text)

    # Append phase data to session ledger
    if session_file:
        phase_data = {
            "name": phase_name,
            "duration_s": round(duration_ms / 1000, 1),
            "cost_usd": round(cost_usd, 6),
            "tools_used": tool_count,
        }
        try:
            if os.path.exists(session_file):
                with open(session_file, "r") as f:
                    session = json.load(f)
            else:
                session = {"phases": []}

            session["phases"].append(phase_data)

            with open(session_file, "w") as f:
                json.dump(session, f, indent=2)
        except (json.JSONDecodeError, IOError):
            pass  # don't break the pipeline over session bookkeeping

    # Print phase cost summary
    duration_s = round(duration_ms / 1000, 1)
    if duration_ms > 0:
        print(
            f"\n  {DIM}{duration_s}s | ${cost_usd:.4f} | "
            f"{tool_count} tool calls{NC}",
            flush=True,
        )

    # Exit with error if no result was received (claude may have failed)
    if not final_text and output_file:
        sys.exit(1)


if __name__ == "__main__":
    main()
