#!/usr/bin/env python3
"""
Stream processor for dev-harness.
Reads claude --output-format stream-json from stdin, displays live tool
calls and text with a spinner + live token counter, writes the final
result to an artifact file, and appends phase cost/duration to the
session ledger.
"""

import sys
import json
import os
import threading
import time

# ANSI colors
CYAN = "\033[0;36m"
BRIGHT_CYAN = "\033[1;36m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[0;32m"
BRIGHT_GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
NC = "\033[0m"

# Cursor control
HIDE_CURSOR = "\033[?25l"
SHOW_CURSOR = "\033[?25h"
CLEAR_LINE = "\033[2K\r"

# Spinner frames
SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

# Tool display names and primary input key
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
    "Agent": ("Agent", "prompt"),
}


def fmt_tokens(n):
    """Format token count with K suffix."""
    if n >= 1000:
        return f"{n / 1000:.1f}K"
    return str(n)


def format_tool_detail(name, inp):
    """Extract a short, readable detail string from tool input."""
    if name in TOOL_DISPLAY:
        _, key = TOOL_DISPLAY[name]
        val = inp.get(key, "")
    else:
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
        val = val.split("\n")[0]
        if len(val) > 55:
            val = val[:52] + "..."

    if len(val) > 60:
        val = val[:57] + "..."

    return val


class StatusLine:
    """Manages the spinner and live token counter on a single line."""

    def __init__(self):
        self.active = False
        self.label = "Thinking"
        self.tokens_in = 0
        self.tokens_out = 0
        self.start_time = time.time()
        self._frame = 0
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()

    def start(self):
        self.active = True
        self._stop.clear()
        sys.stdout.write(HIDE_CURSOR)
        sys.stdout.flush()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            with self._lock:
                elapsed = time.time() - self.start_time
                frame = SPINNER[self._frame % len(SPINNER)]
                self._frame += 1

                tok_str = ""
                total = self.tokens_in + self.tokens_out
                if total > 0:
                    tok_str = (
                        f" {DIM}│{NC} "
                        f"{fmt_tokens(total)} tok "
                        f"{DIM}(in:{fmt_tokens(self.tokens_in)} "
                        f"out:{fmt_tokens(self.tokens_out)}){NC}"
                    )

                line = (
                    f"{CLEAR_LINE}"
                    f"  {BRIGHT_CYAN}{frame}{NC} "
                    f"{DIM}{self.label}{NC}"
                    f" {DIM}│{NC} {DIM}{elapsed:.0f}s{NC}"
                    f"{tok_str}"
                )
                sys.stdout.write(line)
                sys.stdout.flush()

            self._stop.wait(0.1)

    def update(self, label=None, tokens_in=None, tokens_out=None):
        with self._lock:
            if label is not None:
                self.label = label
            if tokens_in is not None:
                self.tokens_in = tokens_in
            if tokens_out is not None:
                self.tokens_out = tokens_out

    def clear(self):
        """Clear the status line so other output can print cleanly."""
        sys.stdout.write(CLEAR_LINE)
        sys.stdout.flush()

    def stop(self):
        if self.active:
            self._stop.set()
            if self._thread:
                self._thread.join(timeout=1)
            sys.stdout.write(CLEAR_LINE + SHOW_CURSOR)
            sys.stdout.flush()
            self.active = False


def main():
    output_file = sys.argv[1] if len(sys.argv) > 1 else None
    phase_name = sys.argv[2] if len(sys.argv) > 2 else "unknown"
    session_file = sys.argv[3] if len(sys.argv) > 3 else None

    final_text = ""
    duration_ms = 0
    cost_usd = 0.0
    usage = {}
    tool_count = 0
    text_started = False

    # Running token accumulator (updated from usage events)
    running_input = 0
    running_output = 0

    status = StatusLine()
    status.start()

    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            etype = event.get("type", "")

            # Track tokens from usage events within the stream
            if "usage" in event:
                u = event["usage"]
                running_input = u.get("input_tokens", running_input)
                running_output = u.get("output_tokens", running_output)
                status.update(
                    tokens_in=running_input + u.get("cache_read_input_tokens", 0),
                    tokens_out=running_output,
                )

            if etype == "assistant":
                content = event.get("message", {}).get("content", [])

                # Check message-level usage
                msg_usage = event.get("message", {}).get("usage", {})
                if msg_usage:
                    running_input = msg_usage.get("input_tokens", running_input)
                    running_output = msg_usage.get("output_tokens", running_output)
                    status.update(
                        tokens_in=running_input + msg_usage.get("cache_read_input_tokens", 0),
                        tokens_out=running_output,
                    )

                for block in content:
                    btype = block.get("type", "")

                    if btype == "tool_use":
                        name = block.get("name", "?")
                        inp = block.get("input", {})
                        detail = format_tool_detail(name, inp)
                        display_name = TOOL_DISPLAY.get(name, (name, ""))[0]

                        if text_started:
                            sys.stdout.write("\n")
                            text_started = False

                        status.clear()
                        print(
                            f"  {BRIGHT_CYAN}> {CYAN}{display_name:<9}{NC}"
                            f" {DIM}{detail}{NC}",
                            flush=True,
                        )
                        tool_count += 1
                        status.update(label=f"{display_name} {detail[:30]}")

                    elif btype == "text":
                        text = block.get("text", "")
                        if text:
                            if not text_started and tool_count > 0:
                                status.clear()
                                print(
                                    f"\n  {DIM}{'─' * 50}{NC}\n",
                                    flush=True,
                                )
                            status.stop()
                            text_started = True
                            sys.stdout.write(text)
                            sys.stdout.flush()

            elif etype == "result":
                final_text = event.get("result", "")
                duration_ms = event.get("duration_ms", 0)
                cost_usd = event.get("total_cost_usd", 0.0)
                usage = event.get("usage", {})

    except KeyboardInterrupt:
        pass
    finally:
        status.stop()

    # Ensure final newline after streamed text
    if text_started:
        sys.stdout.write("\n")

    # Write artifact file
    if output_file and final_text:
        os.makedirs(os.path.dirname(output_file) or ".", exist_ok=True)
        with open(output_file, "w") as f:
            f.write(final_text)

    # Compute token totals
    input_tokens = usage.get("input_tokens", 0)
    output_tokens = usage.get("output_tokens", 0)
    cache_read = usage.get("cache_read_input_tokens", 0)
    cache_create = usage.get("cache_creation_input_tokens", 0)
    total_tokens = input_tokens + output_tokens + cache_read + cache_create

    # Append phase data to session ledger
    if session_file:
        phase_data = {
            "name": phase_name,
            "duration_s": round(duration_ms / 1000, 1),
            "cost_usd": round(cost_usd, 6),
            "tools_used": tool_count,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cache_read_tokens": cache_read,
            "cache_creation_tokens": cache_create,
            "total_tokens": total_tokens,
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
            pass

    # Print phase summary
    duration_s = round(duration_ms / 1000, 1)
    if duration_ms > 0:
        token_parts = []
        if input_tokens:
            token_parts.append(f"in:{fmt_tokens(input_tokens)}")
        if output_tokens:
            token_parts.append(f"out:{fmt_tokens(output_tokens)}")
        if cache_read:
            token_parts.append(f"cache:{fmt_tokens(cache_read)}")
        token_str = " ".join(token_parts)

        print(
            f"\n  {DIM}{duration_s}s | ${cost_usd:.4f} | "
            f"{fmt_tokens(total_tokens)} tokens ({token_str}) | "
            f"{tool_count} tool calls{NC}",
            flush=True,
        )

    # Exit with error if no result was received
    if not final_text and output_file:
        sys.exit(1)


if __name__ == "__main__":
    main()
