# dev-harness TODO: Live Streaming & UI Polish

## What's done (this commit)
- Interactive dashboard mode (run `harness` with no args to get menu)
- Task history tracking in `.harness/history.log`
- Artifact status display (green dots, file sizes, timestamps)
- Artifact viewer from the menu (pipes to `less` for large files)
- `--quiet` flag for silent mode, live `tee` output as default
- `install.sh` for global `harness` command via `~/.local/bin`

## What's in progress: Real-time streaming

The `tee` approach doesn't actually stream — `claude -p` buffers all output and dumps it at the end. You see nothing while the agent works, then a wall of text.

### The fix: use `--output-format stream-json --verbose`

Claude CLI supports `stream-json` which emits one JSON event per line in real time:
- `{"type":"system","subtype":"init",...}` — session start
- `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{...}}]}}` — tool calls
- `{"type":"assistant","message":{"content":[{"type":"text","text":"..."}]}}` — text output
- `{"type":"result","result":"...final text...","duration_ms":...}` — final result

### Implementation plan

1. **Replace `run_phase()` to use stream-json** — change the claude invocation:
   ```bash
   claude -p --verbose --output-format stream-json \
     --dangerously-skip-permissions "$prompt" 2>>"$LOG_FILE"
   ```

2. **Write a Python stream processor** — inline or as a separate file, piped from claude:
   ```
   claude ... | python3 stream_processor.py "$output_file"
   ```
   The processor should:
   - Parse each JSON line as it arrives
   - On `tool_use` events: print formatted line like `  > Read  src/index.ts`
   - On `text` content: stream it to terminal character by character
   - On `result`: extract `.result` field, write it to `$output_file`
   - Show elapsed time and cost from the result event

3. **Color scheme for streaming output**:
   - Tool names in cyan/bold: `  > Read`, `  > Edit`, `  > Bash`
   - Tool inputs dimmed: file paths, commands
   - Text output in default color, streamed live
   - Phase headers more prominent — use box-drawing characters
   - Elapsed time in dim after each tool completes

4. **Example of what the user should see during a phase**:
   ```
   ════════ Builder ════════

     Running Builder agent...

     > Read   src/components/Auth.tsx
     > Read   src/lib/jwt.ts
     > Edit   src/components/Auth.tsx
     > Bash   npm test
     > Edit   src/lib/jwt.ts
     > Bash   npm test

     Building response...

     ── Builder output ──────────────────
     ### Changes made
     - Modified `src/components/Auth.tsx` — added JWT validation
     ...
     ── end ─────────────────────────────

     ✓ Builder completed in 47s — output saved: .harness/build-result.md
   ```

5. **UI polish items**:
   - More vibrant banner with gradient-style box
   - Spinner/activity indicator while waiting for first stream event
   - Phase progress bar: `[■■□□] 2/4 Planner`
   - Cost tracking: show running total across phases
   - Color the menu numbers and make active selection more obvious
   - After pipeline completes, show a summary card with all phase times + total cost

6. **The stream processor (Python)** — save as `.harness/stream.py` or embed in harness.sh via heredoc:
   ```python
   #!/usr/bin/env python3
   """Stream processor for claude --output-format stream-json"""
   import sys, json

   output_file = sys.argv[1] if len(sys.argv) > 1 else None
   final_text = ""

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
               if block.get("type") == "tool_use":
                   name = block.get("name", "?")
                   inp = block.get("input", {})
                   # Format tool call for display
                   detail = ""
                   if "file_path" in inp:
                       detail = inp["file_path"].split("/")[-1]
                   elif "command" in inp:
                       detail = inp["command"][:60]
                   elif "pattern" in inp:
                       detail = inp["pattern"]
                   print(f"\033[0;36m  > {name:<8}\033[2m {detail}\033[0m", flush=True)
               elif block.get("type") == "text":
                   # Stream text to terminal
                   sys.stdout.write(block.get("text", ""))
                   sys.stdout.flush()

       elif etype == "result":
           final_text = event.get("result", "")
           duration = event.get("duration_ms", 0)
           cost = event.get("total_cost_usd", 0)
           if duration:
               print(f"\n\033[2m  {duration/1000:.1f}s | ${cost:.4f}\033[0m", flush=True)

   # Write final result to output file
   if output_file and final_text:
       with open(output_file, "w") as f:
           f.write(final_text)
   ```

7. **Updated `run_phase()` (non-quiet mode)**:
   ```bash
   # Create stream processor on first use
   if [[ ! -f "$HARNESS_DIR/stream.py" ]]; then
     create_stream_processor  # writes the python script
   fi

   phase "$name"
   log "Starting phase: $name"
   info "Running $name agent..."

   local start_time=$SECONDS
   claude -p --verbose --output-format stream-json \
     --dangerously-skip-permissions \
     "$prompt" \
     2>>"$LOG_FILE" | python3 "$HARNESS_DIR/stream.py" "$output_file"
   ```

## Notes
- `python3` is required for the stream processor (available on essentially all dev machines)
- The `--verbose` flag is required by claude CLI when using `--output-format stream-json`
- The stream processor handles the dual responsibility: live display AND artifact file writing
- Quiet mode (`--quiet`) stays unchanged — direct stdout redirect, no streaming
