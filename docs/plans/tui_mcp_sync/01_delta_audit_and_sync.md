# Step 10 → 11 delta audit: MCP implementation & loader

Trigger: after the "Huge refactor bringing in MCP amd Mud manager log
dashboard" work landed in
[`10_standard_tool_library`](../../../week1_baseline/ruby/10_standard_tool_library),
there was a concern that
[`11_tui`](../../../week1_baseline/ruby/11_tui) might be behind — missing the
MCP implementation and/or the loader improvements. This plan documents a full
file-by-file audit (`diff -rq` across both trees, then a manual diff of every
file it flagged) and what, if anything, needs to change.

## Headline finding: there is no MCP delta

`11_tui`'s `lib/boukensha/mcp/client.rb` and `lib/boukensha/tools/mcp.rb` are
**byte-identical** to `10_standard_tool_library`'s. So are `agent.rb`,
`client.rb`, `config.rb`, `context.rb`, `errors.rb`, `logger.rb`, `message.rb`,
`prompt_builder.rb`, `registry.rb`, `run_dsl.rb`, `tool.rb`, `tasks/*`, and all
of `backends/*`. `git log --follow` on the mcp files shows both copies were
added together, in the same commit (`7f04047` — "Ensuring Config Runs"), so
they've never diverged. There is nothing to port.

`boukensha_loader.rb`'s actual resolution logic (`~/.boukensharc` YAML
parsing, `BOUKENSHA_PATH`/`BOUKENSHA_DIR` precedence, bare-string backward
compat) is likewise identical in both steps — confirmed line-by-line, not just
by the absence of a `diff -rq` hit. The only differences in that file are:

- an added `--no-tui` flag (`11_tui` only — intentional TUI wiring), and
- a documentation comment about MUD env var precedence present in `10`'s
  header but not copied into `11`'s (see cosmetic sync item below).

## What actually differs, and why it's correct

Every other difference `diff -rq` found is the intentional step-11 feature —
wrapping the existing REPL in a `charm`-based TUI — not a missing backport:

| File | Nature of the diff |
|------|---------------------|
| `lib/boukensha/tui.rb` | New in `11_tui`. The TUI itself. |
| `patches/bubbletea/*` | New in `11_tui`. Native-extension patch for the `bubbletea` gem the TUI depends on. |
| `lib/boukensha/repl.rb` | Refactored so `Repl` no longer hard-codes `puts`/`gets`: output goes through an `on_output` callback, slash-command handling is pulled into `handle_command`, and `banner`/`logger`/`context`/`model`/`version` are exposed as readers. Behavior for the plain REPL (`--no-tui`) is unchanged — same banner, same commands, same MCP servers-status line. |
| `lib/boukensha.rb` | Adds the `tui:` keyword to `Boukensha.repl` (default `true`), dispatching to `Tui.new(repl).start` or `repl.start`. |
| `boukensha.gemspec`, `Gemfile`, `Gemfile.lock` | Add the `charm` dependency (bubbletea/lipgloss/bubbles/etc.) needed only for the TUI. MCP servers still bring their own dependencies, unchanged. |
| `lib/boukensha/version.rb` | `0.10.0` → `0.11.1`. |
| `README.md`, `examples/example.rb` | Updated step number/version and TUI documentation. |

None of this needs to change — it's the correct, already-complete step-11
delta on top of a shared, unmodified MCP core.

## Remaining items (cosmetic parity only)

These are not functional gaps; they're small doc/asset asymmetries surfaced
by the audit that are worth cleaning up for consistency:

1. **Loader header comment.** `10`'s `boukensha_loader.rb` documents that MUD
   connection details come from `settings.yaml`'s `mud:` block and that
   legacy `MUD_*` env vars still take precedence when set. `11`'s header
   dropped that paragraph when it added the `--no-tui` line. The code behavior
   is identical (confirmed above) — only the comment needs to be carried over
   so `11`'s file documents the same precedence rules `10` does.
   - File: `week1_baseline/ruby/11_tui/lib/boukensha_loader.rb`
   - Action: re-add the MUD-env-var-precedence paragraph alongside the
     existing `--no-tui` line, rather than replacing one with the other.

2. **No committed gem artifact for `11_tui`.** `10_standard_tool_library` has
   `boukensha-0.10.0.gem` checked in (per the repo's per-step packaging
   convention — see recent commit "Add built boukensha-0.9.0 gem artifact and
   executable"). `11_tui` has no `boukensha-0.11.1.gem`.
   - Action: `cd week1_baseline/ruby/11_tui && gem build boukensha.gemspec`
     and commit the resulting `.gem` if the convention should hold for this
     step too. Confirm with the user before committing a built binary artifact.

3. **Dangling doc link (out of scope, flagging only).** Both `10`'s and
   `11`'s README point at
   `docs/plans/floating_artifacts/bounkensharc.md` for the `.boukensharc`
   incident writeup. That file does not exist anywhere in the repo — the
   directory `docs/plans/floating_artifacts/` isn't present. Not part of this
   MCP/loader delta; worth a separate follow-up so the link isn't dead in
   either step.

## Steps to execute

1. Edit `week1_baseline/ruby/11_tui/lib/boukensha_loader.rb`: restore the
   MUD-env-var-precedence comment paragraph (item 1).
2. Decide with the user whether to build + commit
   `boukensha-0.11.1.gem` for `11_tui` (item 2) — this is a binary artifact
   commit, confirm before doing it.
3. Re-run `11_tui`'s test suite (`bundle exec rake test`) to confirm nothing
   regressed — expected to be a no-op since only a comment changes.
4. Smoke-test both entry points from `11_tui`:
   - `BOUKENSHA_DIR=.boukensha BOUKENSHA_PATH=$(pwd) boukensha --no-tui`
     (plain REPL path — exercises the shared loader/REPL/MCP code)
   - `BOUKENSHA_DIR=.boukensha BOUKENSHA_PATH=$(pwd) boukensha`
     (TUI path)
5. (Separate/optional) File a follow-up for the dangling
   `floating_artifacts/bounkensharc.md` link (item 3) — not blocking this sync.

## Verification that no further MCP delta exists

Re-run the audit after any future change to `10_standard_tool_library`'s MCP
layer:

```sh
diff -rq week1_baseline/ruby/10_standard_tool_library week1_baseline/ruby/11_tui \
  --exclude=".git" --exclude="*.gem" --exclude="Gemfile.lock"
```

Any hit outside the known TUI-only file set above (`tui.rb`, `patches/`,
`repl.rb`, `boukensha.rb`, `boukensha_loader.rb`'s `--no-tui` line, gemspec/
Gemfile/version/README) signals a real MCP or loader change in `10` that has
not yet been ported to `11` and needs the same file copied across.
