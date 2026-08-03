# Step 11 → 12 delta audit: TUI/MCP improvements & context management

Trigger: a concern that [`12_context`](../../../week1_baseline/ruby/12_context)
— built to add context-window/model-aware management on top of
[`11_tui`](../../../week1_baseline/ruby/11_tui) — might be missing
improvements landed in `11_tui` (the bubbletea TUI, the REPL callback
refactor, MCP client hardening) because it looked like a stale fork rather
than a forward port. This plan documents a full file-by-file audit
(`diff -rq` across both trees, then a manual line-by-line diff of every file
it flagged, done via three parallel deep-dive passes covering
backends/config, core runtime, and docs/examples/tests) and what, if
anything, needed to change.

This is the same style of audit as
[`tui_mcp_sync/01`](../tui_mcp_sync/01_delta_audit_and_sync.md) (which did
`10_standard_tool_library` → `11_tui` and found the MCP core untouched); this
one covers the next step pair and a much larger, genuinely-evolved diff.

## Headline finding: no functional gap — `12_context` is a correct superset

`diff -rq` flagged 21 of ~29 files as differing (unlike the 10→11 audit,
where the core was byte-identical). Reading every diff against both versions
shows all of it is either `12_context`'s own legitimate step-12 work, or an
11_tui improvement that was already carried forward correctly. Nothing from
`11_tui` was dropped or regressed.

### Confirmed byte-identical (no delta, no action)

`bin/boukensha`, `boukensha.gemspec`, `Gemfile`, `patches/bubbletea/*` (all
files), `prompts/system.md`, `Rakefile`, `test/test_boukensha_loader.rb`,
`test/test_mcp_client.rb`, `test/test_mcp_servers_config.rb`,
`test/test_tools_mcp.rb`.

### Core runtime — TUI and REPL refactor carried forward intact

| File | Verdict |
|------|---------|
| `lib/boukensha/repl.rb` | Carried forward + extended. The 11-era `on_output`/`handle_command` callback refactor is present unchanged; 12 additively adds a `/compact` command and swaps `task_settings:`/`max_iterations:` kwargs for `max_iterations:`/`max_turn_tokens:`/`max_output_tokens:`. No regression to a pre-refactor REPL. |
| `lib/boukensha/tui.rb` | Carried forward + extended. Full bubbletea TUI (`Msg`, keymaps, `render_status`, spinner) retained; adds `CTX_WARN_PCT`/`CTX_ALERT_PCT`, `ctx_color(pct)`, and a `"compaction"` event handler on top. Old session-cumulative token counters replaced by `Context#usage_pct`/`current_tokens`, consistent with the new context feature. |
| `lib/boukensha.rb` | Carried forward. `tui:` keyword on `Boukensha.repl` and `Tui.new(repl).start` dispatch unchanged; both `.task` and `.repl` now also resolve `context_window` via the new `Models.context_window(model)` and read agent limits from `cfg.agent_max_*` instead of `task_class.max_iterations`. |
| `lib/boukensha/mcp/client.rb` | Both 11-era fixes present verbatim: `spawn_unbundled` (wraps `Open3.popen3` in `Bundler.with_unbundled_env` so `BUNDLE_GEMFILE`/`RUBYOPT` don't leak into the MCP subprocess env) and `stderr_detail` (drains stderr on unexpected EOF for a diagnosable error instead of a bare "server closed the connection"). |
| `lib/boukensha/agent.rb` | 11's reasoning-block logging (`log_reasoning`, `preamble`/`plan` split out of `log_response`, `extract_text` joining with `"\n"`) is present. 12 additionally reworks limits to token-budget tracking (`token_limit_reached?`, `record_usage`, `compact_if_needed`) tied to `Context#turn_tokens`/`needs_compaction?` — legitimate step-12 layer on top. |
| `lib/boukensha/context.rb` | 12-only additive API: `context_window`, `turn_tokens`, `current_tokens`, `usage_pct`, `needs_compaction?`, `compact_messages!` (drops oldest 40%, min-keep 2), replacing the old `task:`/`@task` field. No 11_tui capability lost. |
| `lib/boukensha/logger.rb` | Additive: `reasoning(text:, redacted:)`/`plan(text:)` from 11's agent refactor are present; 12 adds `context_window:` to `prompt` and a new `compaction(...)` event. |
| `lib/boukensha/version.rb` | Cosmetic: `0.11.1` → `0.12.0`. |
| `lib/boukensha_loader.rb` | Was doc-only gap — see cleanup item 1 below (now fixed). |

### Backends/config — all diffs are 12's own reasoning/context work

| File | Verdict |
|------|---------|
| `backends/anthropic.rb` | Additive: `normalize_block`/`denormalize_block` map native `thinking`/`redacted_thinking` to the shared `"reasoning"` block shape; `to_messages` gains a `:assistant` case to re-serialize reasoning blocks. 11_tui has no reasoning support — nothing to carry forward. |
| `backends/base.rb` | Cosmetic: adds a comment block documenting the normalized `{stop_reason, content}` contract incl. `"reasoning"`. Logic unchanged. |
| `backends/gemini.rb` | Additive: `thinking_config` (disables default "thinking"), reasoning-block parsing (`part["thought"]`), signature round-tripping. |
| `backends/ollama.rb` | Additive: `think: false` + reasoning-block extraction from `message["thinking"]`. |
| `backends/ollama_cloud.rb` | Same additive `think: false`/reasoning change; model-hash entries reordered (cosmetic). |
| `backends/openai.rb` | **Largest diff in the audit.** Migrates the entire backend from Chat Completions (`/v1/chat/completions`) to the Responses API (`/v1/responses`) — per its own header comment, because "gpt-5.x rejects `reasoning_effort` + tools on chat completions." Deliberate, self-contained rewrite of `to_messages`→`to_input`, `to_tools`, `parse_response`. Not a missing 11_tui port. Flagged separately below as a risk area. |
| `lib/boukensha/config.rb` | Purely additive: `provider_type`/`model` accessors, four `agent_max_*`/`agent_compaction_threshold` methods. Zero deletions besides a `to_s` tweak. |
| `lib/boukensha/errors.rb` | Cosmetic whitespace only. |
| `lib/boukensha/prompt_builder.rb` | Cosmetic doc-comment only; delegation logic unchanged. |
| `lib/boukensha/models.rb` (12-only) | New file: model→context_window lookup table (`DEFAULT_CONTEXT_WINDOW = 32_000` fallback), lazily built from each backend's `MODELS` constant. No 11_tui dependency. |
| `Gemfile.lock` | Cosmetic/environment drift (version bump, platform-gem variant); not a deliberate improvement to port. |

### Docs/examples/tests — legitimate API adaptations, not dropped content

| File | Verdict |
|------|---------|
| `README.md` | Proper superset: every TUI section from 11_tui (four-zone layout, keyboard shortcuts, `tui:`/`--no-tui`, `Repl` composability, `Logger#subscribe`) is kept, plus all step-12 content added. One real gap found and fixed — see cleanup item 2 below. |
| `examples/example.rb` | Cosmetic: only the "Step 11"→"Step 12" comment header changes. |
| `examples/mcp_mud_demo.rb` | Legitimate adaptation: `Context.new(task: Tasks::Player, ...)` → `Context.new(system: ...)` because `Context#initialize` no longer takes `task:` — task/model resolution moved to `Tasks::Base`/`Tasks::Player`. Not a dropped feature. |
| `test/helper.rb` | Same root cause as above — `new_registry` updated to match the new `Context.new` signature. |

## Cleanup items — applied

1. **Loader doc-comment parity (applied).** `11_tui/lib/boukensha_loader.rb`
   had a locally-added header paragraph (uncommitted at audit time)
   documenting that MCP server env vars come from `settings.yaml`'s
   `mcp_servers:` block and that config wins over an inherited legacy env
   var. `12_context`'s copy of the same header never had it. Inserted the
   identical paragraph into
   `week1_baseline/ruby/12_context/lib/boukensha_loader.rb`, between the
   `~/.boukensharc` bullet list and the `--no-tui` line. Comment-only, no
   behavior change (resolution logic was already identical in both files).

2. **README intro: name the TUI library explicitly (applied).**
   `11_tui`'s opening paragraph names the `charm` gem and its components;
   `12_context`'s opening paragraph only said "the terminal UI carried
   forward from earlier steps" with no library name/link (the functional TUI
   docs later in the file were intact — this was just the intro). Reworded
   `week1_baseline/ruby/12_context/README.md`'s opening paragraph to keep the
   context-management framing while re-adding the `charm` gem name/link.

3. **Gem artifact convention — pending a decision.** Per the repo's
   per-step packaging convention (e.g. commit "Add built boukensha-0.9.0 gem
   artifact and executable"; also flagged in `tui_mcp_sync/01` item 2):
   `11_tui` has an **untracked** `boukensha-0.11.1.gem` in its working tree.
   `12_context` *had* a committed `boukensha-0.12.0.gem` that was deleted in
   commit `7f04047` ("Ensuring Config Runs") and never replaced. Rebuilding
   and committing gem artifacts is a binary-artifact commit — needs explicit
   user confirmation before doing it for either step, so this is left as an
   open decision rather than auto-applied.

## Flagged, out of scope (record only, no action taken)

- **OpenAI backend risk area.** The Responses-API migration in
  `backends/openai.rb` is new, substantial, and self-contained — worth a
  dedicated correctness review of its own (message/tool-call round-tripping
  via `call_id`, `output[]` item-type parsing), separate from this
  improvement-carry-forward audit.
- **Dangling doc link, asymmetric.** `11_tui/README.md`'s "Technical
  Considerations" section links `docs/plans/floating_artifacts/bounkensharc.md`,
  which doesn't exist in the repo (already flagged in `tui_mcp_sync/01` item
  3, still unresolved there). `12_context` dropped that whole section, so
  the dead link only exists in `11_tui`. No action needed in `12_context`.

## Verification

- `lib/boukensha_loader.rb` and `README.md` now carry the same
  documentation paragraphs in both `11_tui` and `12_context` — re-run
  `diff -u` on each pair to confirm only the intended wording differs
  (version numbers, step titles).
- Re-run `12_context`'s test suite (`rake test`) following the WSL setup in
  [`tui_mcp_sync/02`](../tui_mcp_sync/02_running_tests_in_wsl.md) — the same
  native-extension/Windows-path constraints apply since `12_context` also
  depends on `charm`. Expected: no change in pass count, since both edits
  are comment/doc-only.
- Gem artifact item 3 stays open until the user decides whether to build +
  commit `.gem` files for `11_tui`/`12_context`.

## Re-run recipe (future changes)

```sh
diff -rq week1_baseline/ruby/11_tui week1_baseline/ruby/12_context \
  --exclude=".git" --exclude="*.gem" --exclude="Gemfile.lock"
```

Any hit outside the known file set documented above (backends/, config.rb,
context.rb, models.rb, agent.rb's token-budget code, repl.rb's `/compact`,
tui.rb's context bar, README/examples task-arg adaptations) signals a real
backport gap between the two steps and needs the same file-by-file treatment
this audit used.
