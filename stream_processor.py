#!/usr/bin/env python3
"""
Stream processor for dev-harness.
Reads claude --output-format stream-json from stdin, displays live tool
calls (with full inputs and outputs), Claude's reasoning text, and a
spinner + live token/cost counter. Writes the final result to an artifact
file and appends phase cost/duration to the session ledger.
"""

import sys
import json
import os
import shutil
import textwrap
import threading
import time


def get_term_width(default=80):
    """Return current terminal width, falling back to *default*."""
    try:
        return shutil.get_terminal_size((default, 24)).columns
    except Exception:
        return default


# ANSI colors
CYAN = "\033[0;36m"
BRIGHT_CYAN = "\033[1;36m"
DIM = "\033[2m"
BOLD = "\033[1m"
GREEN = "\033[0;32m"
BRIGHT_GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
MAGENTA = "\033[0;35m"
NC = "\033[0m"

# Cursor control
HIDE_CURSOR = "\033[?25l"
SHOW_CURSOR = "\033[?25h"
CLEAR_LINE = "\033[2K\r"

# Spinner frames
SPINNER = ["\u28cb", "\u28d9", "\u28f9", "\u28f8", "\u28fc", "\u28f4", "\u28e6", "\u28e7", "\u28c7", "\u28cf"]

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

# Approximate pricing per million tokens (USD)
MODEL_PRICING = {
    "opus": {"input": 15.0, "output": 75.0, "cache_read": 1.50},
    "sonnet": {"input": 3.0, "output": 15.0, "cache_read": 0.30},
    "haiku": {"input": 0.80, "output": 4.0, "cache_read": 0.08},
    "default": {"input": 15.0, "output": 75.0, "cache_read": 1.50},
}

# Max lines to show for tool results before truncating
TOOL_RESULT_MAX_LINES = 25


def get_pricing(model_name):
    """Get pricing dict for a model name (fuzzy match)."""
    model_lower = (model_name or "").lower()
    for key in MODEL_PRICING:
        if key in model_lower:
            return MODEL_PRICING[key]
    return MODEL_PRICING["default"]


def estimate_cost(pricing, input_tokens, output_tokens, cache_read_tokens=0):
    """Estimate cost in USD from token counts."""
    cost = (
        (input_tokens / 1_000_000) * pricing["input"]
        + (output_tokens / 1_000_000) * pricing["output"]
        + (cache_read_tokens / 1_000_000) * pricing["cache_read"]
    )
    return cost


def fmt_tokens(n):
    """Format token count with K suffix."""
    if n >= 1000:
        return f"{n / 1000:.1f}K"
    return str(n)


def fmt_cost(cost):
    """Format cost as $X.XX or $X.XXXX for small amounts."""
    if cost >= 0.01:
        return f"${cost:.2f}"
    elif cost > 0:
        return f"${cost:.4f}"
    return ""


def indent_block(text, prefix="    "):
    """Indent every line of text with a prefix."""
    lines = text.split("\n")
    return "\n".join(prefix + line for line in lines)


def truncate_lines(text, max_lines):
    """Truncate text to max_lines, adding a note if truncated."""
    lines = text.split("\n")
    if len(lines) <= max_lines:
        return text
    kept = lines[:max_lines]
    omitted = len(lines) - max_lines
    kept.append(f"  ... ({omitted} more lines)")
    return "\n".join(kept)


def format_tool_input_full(name, inp):
    """Format the full tool input for display."""
    display_name = TOOL_DISPLAY.get(name, (name, ""))[0]
    parts = []

    if name == "Bash":
        cmd = inp.get("command", "")
        desc = inp.get("description", "")
        if desc:
            parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}  {DIM}{desc}{NC}")
        else:
            parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}")
        if cmd:
            parts.append(f"  {DIM}${NC} {cmd}")

    elif name in ("Read", "Write"):
        fpath = inp.get("file_path", "")
        parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}  {fpath}")
        if name == "Read":
            offset = inp.get("offset")
            limit = inp.get("limit")
            if offset or limit:
                extra = []
                if offset:
                    extra.append(f"offset={offset}")
                if limit:
                    extra.append(f"limit={limit}")
                parts.append(f"    {DIM}{', '.join(extra)}{NC}")

    elif name == "Edit":
        fpath = inp.get("file_path", "")
        old = inp.get("old_string", "")
        new = inp.get("new_string", "")
        parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}  {fpath}")
        if old:
            old_preview = old.strip().split("\n")
            if len(old_preview) > 5:
                old_preview = old_preview[:5] + ["..."]
            parts.append(f"    {RED}- {DIM}" + f"\n    {RED}- {DIM}".join(old_preview) + NC)
        if new:
            new_preview = new.strip().split("\n")
            if len(new_preview) > 5:
                new_preview = new_preview[:5] + ["..."]
            parts.append(f"    {GREEN}+ {DIM}" + f"\n    {GREEN}+ {DIM}".join(new_preview) + NC)

    elif name in ("Grep", "Glob"):
        pattern = inp.get("pattern", "")
        path = inp.get("path", "")
        parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}  {YELLOW}{pattern}{NC}")
        if path:
            parts.append(f"    {DIM}in {path}{NC}")
        extras = []
        if name == "Grep":
            if inp.get("glob"):
                extras.append(f"glob={inp['glob']}")
            if inp.get("type"):
                extras.append(f"type={inp['type']}")
            if inp.get("output_mode"):
                extras.append(f"mode={inp['output_mode']}")
        if extras:
            parts.append(f"    {DIM}{', '.join(extras)}{NC}")

    elif name == "Agent":
        prompt = inp.get("prompt", "")
        desc = inp.get("description", "")
        parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}  {DIM}{desc}{NC}")
        if prompt:
            preview = prompt.strip()[:200]
            if len(prompt.strip()) > 200:
                preview += "..."
            parts.append(f"    {DIM}{preview}{NC}")

    elif name in ("WebSearch", "WebFetch"):
        query_or_url = inp.get("query", inp.get("url", ""))
        parts.append(f"  {BRIGHT_CYAN}> {CYAN}{display_name}{NC}  {query_or_url}")

    else:
        # Generic fallback
        parts.append(f"  {BRIGHT_CYAN}> {CYAN}{name}{NC}")
        for k, v in inp.items():
            val_str = str(v)
            if len(val_str) > 120:
                val_str = val_str[:117] + "..."
            parts.append(f"    {DIM}{k}: {val_str}{NC}")

    return "\n".join(parts)


def format_tool_result(event):
    """Format tool result output from a 'user' type event."""
    content_list = event.get("message", {}).get("content", [])
    # Also check tool_use_result for richer data
    tool_result = event.get("tool_use_result", {})

    parts = []

    for item in content_list:
        if item.get("type") == "tool_result":
            result_text = item.get("content", "")
            if isinstance(result_text, list):
                # Content can be a list of blocks
                for block in result_text:
                    if isinstance(block, dict) and block.get("type") == "text":
                        result_text = block.get("text", "")
                        break
                else:
                    result_text = str(result_text)
            if result_text:
                result_text = str(result_text).strip()
                result_text = truncate_lines(result_text, TOOL_RESULT_MAX_LINES)
                parts.append(f"    {DIM}{result_text}{NC}")

    # If tool_use_result has file content, show it
    if not parts and tool_result:
        tr_type = tool_result.get("type", "")
        if tr_type == "text":
            file_info = tool_result.get("file", {})
            if file_info:
                content = file_info.get("content", "")
                if content:
                    content = truncate_lines(content.strip(), TOOL_RESULT_MAX_LINES)
                    parts.append(f"    {DIM}{content}{NC}")

    return "\n".join(parts) if parts else ""


class StatusLine:
    """Manages the spinner and live token/cost counter on a single line."""

    def __init__(self, pricing):
        self.active = False
        self.label = "Thinking"
        self.tokens_in = 0
        self.tokens_out = 0
        self.cache_read = 0
        self.start_time = time.time()
        self.pricing = pricing
        self._frame = 0
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()

    def start(self):
        if self.active:
            return
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
                    cost = estimate_cost(
                        self.pricing, self.tokens_in, self.tokens_out, self.cache_read
                    )
                    cost_str = fmt_cost(cost)
                    cost_part = f"  {cost_str}" if cost_str else ""

                    tok_str = (
                        f" {DIM}\u2502{NC} "
                        f"{fmt_tokens(total)} tok "
                        f"{DIM}(in:{fmt_tokens(self.tokens_in)} "
                        f"out:{fmt_tokens(self.tokens_out)}){NC}"
                        f"{cost_part}"
                    )

                line = (
                    f"{CLEAR_LINE}"
                    f"  {BRIGHT_CYAN}{frame}{NC} "
                    f"{DIM}{self.label}{NC}"
                    f" {DIM}\u2502{NC} {DIM}{elapsed:.0f}s{NC}"
                    f"{tok_str}"
                )
                sys.stdout.write(line)
                sys.stdout.flush()

            self._stop.wait(0.1)

    def update(self, label=None, tokens_in=None, tokens_out=None, cache_read=None):
        with self._lock:
            if label is not None:
                self.label = label
            if tokens_in is not None:
                self.tokens_in = tokens_in
            if tokens_out is not None:
                self.tokens_out = tokens_out
            if cache_read is not None:
                self.cache_read = cache_read

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
    model_name = sys.argv[4] if len(sys.argv) > 4 else "default"

    pricing = get_pricing(model_name)

    final_text = ""
    duration_ms = 0
    cost_usd = 0.0
    usage = {}
    tool_count = 0
    text_started = False
    last_was_tool = False  # Track if the last thing printed was a tool call

    # Running token accumulator (updated from usage events)
    running_input = 0
    running_output = 0
    running_cache_read = 0

    status = StatusLine(pricing)
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
                running_cache_read = u.get(
                    "cache_read_input_tokens", running_cache_read
                )
                status.update(
                    tokens_in=running_input + running_cache_read,
                    tokens_out=running_output,
                    cache_read=running_cache_read,
                )

            if etype == "assistant":
                content = event.get("message", {}).get("content", [])

                # Check message-level usage
                msg_usage = event.get("message", {}).get("usage", {})
                if msg_usage:
                    running_input = msg_usage.get("input_tokens", running_input)
                    running_output = msg_usage.get("output_tokens", running_output)
                    running_cache_read = msg_usage.get(
                        "cache_read_input_tokens", running_cache_read
                    )
                    status.update(
                        tokens_in=running_input + running_cache_read,
                        tokens_out=running_output,
                        cache_read=running_cache_read,
                    )

                for block in content:
                    btype = block.get("type", "")

                    if btype == "tool_use":
                        name = block.get("name", "?")
                        inp = block.get("input", {})
                        display_name = TOOL_DISPLAY.get(name, (name, ""))[0]

                        if text_started:
                            sys.stdout.write("\n")
                            text_started = False

                        status.clear()
                        # Print full tool input
                        tool_display = format_tool_input_full(name, inp)
                        print(tool_display, flush=True)
                        tool_count += 1
                        last_was_tool = True

                        # Update spinner label with short summary
                        short = TOOL_DISPLAY.get(name, (name, ""))[1]
                        short_val = str(inp.get(short, ""))[:40] if short else ""
                        status.update(label=f"{display_name} {short_val}")

                    elif btype == "text":
                        text = block.get("text", "")
                        if text:
                            status.clear()
                            if not text_started:
                                # Print a separator + "Claude:" header
                                sep_w = max(get_term_width() - 4, 20)
                                print(
                                    f"\n  {MAGENTA}{BOLD}Claude:{NC}",
                                    flush=True,
                                )
                            status.stop()
                            text_started = True
                            last_was_tool = False
                            # Indent Claude's reasoning for visual clarity
                            for tline in text.split("\n"):
                                sys.stdout.write(f"  {tline}\n")
                            sys.stdout.flush()

            elif etype == "user":
                # This is a tool result — show the output
                result_display = format_tool_result(event)
                if result_display:
                    status.clear()
                    print(result_display, flush=True)

                # Restart spinner after tool result
                if not status.active:
                    status.start()
                status.update(label="Thinking")

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
